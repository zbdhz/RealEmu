// Copyright (C) 2025 Jingzhi Wang
// Email: jzwang@smail.nju.edu.cn
//
// This file is part of RealEmu.
//
// RealEmu is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// RealEmu is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with RealEmu.  If not, see <https://www.gnu.org/licenses/>.

//psz


import GetPut::*;
import FIFOF::*;
import ClientServer::*;
import DReg::*;
import Vector::*;
import Types::*;
import PrimUtils::*;
import FrameTiming::*;
import ReceptionModel::*;

interface PhyCore;
    interface AirSrv lowMacTxSrv;
    interface AirClt lowMacRxClt;
    interface PhySrv phyRxSrv;
    interface PhyClt phyTxClt;
    interface PerSrv perSrv;
    interface Get#(PhyStatus) getPhyStatus;
    interface RegAccessSrv phyRegSrv;
endinterface

typedef struct {
    PhyEvent frame;
    UInt#(32) arrival;
    UInt#(20) symbols;
    UInt#(64) linear;
} TimedSignal deriving(Bits, Eq, FShow);
typedef struct {
    Bool valid;
    PowerDb power;
    UInt#(64) linear;
    UInt#(32) endTime;
    Bit#(32) tag;
    MpduCacheAddr packet;
} ActiveSignal deriving(Bits, Eq, FShow);

module mkPhyYansWifi#(Integer id)(PhyCore);
    FIFOF#(AirFrame) lowMacTxReqQ <- mkFIFOF;
    FIFOF#(Tuple2#(AirFrame,UInt#(20))) preparedTx <- mkFIFOF;
    FIFOF#(GenericResp) lowMacTxRespQ <- mkFIFOF;
    FIFOF#(AirFrame) lowMacRxReqQ <- mkSizedFIFOF(8);
    FIFOF#(GenericResp) lowMacRxRespQ <- mkFIFOF;
    FIFOF#(PhyEvent) phyTxReqQ <- mkFIFOF;
    FIFOF#(GenericResp) phyTxRespQ <- mkFIFOF;
    FIFOF#(Tuple2#(PhyEvent, UInt#(32))) incoming <- mkSizedFIFOF(32);
    FIFOF#(TimedSignal) preparedRx <- mkFIFOF;
    FIFOF#(GenericResp) phyRxRespQ <- mkSizedFIFOF(32);
    FIFOF#(RegAccessReq) phyRegReqQ <- mkFIFOF;
    FIFOF#(RegAccessResp) phyRegRespQ <- mkFIFOF;
    let errors <- mkReceptionModel(id);
    Reg#(UInt#(32)) clock <- mkReg(0);
    Vector#(NODE_NUM, Reg#(ActiveSignal)) signals <- replicateM(mkReg(ActiveSignal{
        valid:False,power:0,linear:0,endTime:0,tag:0,packet:0}));
    Reg#(PhyFsmState) state <- mkReg(PHY_IDLE);
    Reg#(AirFrame) current <- mkReg(toAirFrame(getEmptyMacEvent,0));
    Reg#(UInt#(32)) endTime <- mkReg(0);
    Reg#(UInt#(32)) headerTime <- mkReg(0);
    Reg#(UInt#(32)) boundary <- mkReg(0);
    Reg#(UInt#(64)) chunkNoise <- mkReg(1 << 24);
    Reg#(Bool) chunkCollision <- mkReg(False);
    Reg#(Bool) firstChunk <- mkReg(True);
    Reg#(Bool) headerDone <- mkReg(False);
    Reg#(PowerDb) energyThreshold <- mkReg(128);
    Reg#(UInt#(64)) energyThresholdLinear <- mkReg(linearPower(128));
    Reg#(PowerDb) syncThreshold <- mkReg(128);
    Reg#(PowerDb) interferenceThreshold <- mkReg(128);
    Reg#(Bool) bitModel <- mkReg(False);
    Reg#(Bool) cca <- mkReg(False);
    Reg#(Bool) txStart <- mkDReg(False);
    Reg#(Bool) txEnd <- mkDReg(False);
    Reg#(Bool) rxStart <- mkDReg(False);
    Reg#(AirFrame) startedFrame <- mkReg(toAirFrame(getEmptyMacEvent,0));
    Reg#(Bit#(32)) txTag <- mkReg(0);
    Wire#(Maybe#(RxDecision)) decision <- mkDWire(tagged Invalid);
    Vector#(9, PulseWire) hits <- replicateM(mkPulseWire);
    Vector#(9, Reg#(Bit#(32))) counts <- replicateM(mkReg(0));
    Vector#(9, Reg#(Bit#(32))) snapshot <- replicateM(mkReg(0));
    Reg#(Bit#(32)) snapshotSequence <- mkReg(0);
    PulseWire clearCounters <- mkPulseWire;
    rule ticks;
        clock <= clock + 1;
        for (Integer i=0;i<9;i=i+1) counts[i] <= clearCounters ? 0 : counts[i] + (hits[i] ? 1 : 0);
    endrule
    rule txResponse; phyTxRespQ.deq; endrule
    rule rxResponse; lowMacRxRespQ.deq; endrule
    // Each timing result keeps its complete metadata and acceptance timestamp.
    rule prepareReceive;
        let t = incoming.first; incoming.deq;
`ifdef TRACE_PHY
        $display("PHY prepared id=%0d src=%0d pwr=%0d len=%0d clk=%0d arrival=%0d",id,tpl_1(t).srcPhyId,tpl_1(t).rfParam.power,tpl_1(t).ppduLen,clock,tpl_2(t));
`endif
        preparedRx.enq(TimedSignal{frame:tpl_1(t),arrival:tpl_2(t),symbols:ofdmSymbols(tpl_1(t).ppduLen,tpl_1(t).rfParam.mcs),linear:linearPower(tpl_1(t).rfParam.power)});
    endrule
    rule prepareTransmit;
        let f = lowMacTxReqQ.first; lowMacTxReqQ.deq;
        preparedTx.enq(tuple2(f,ofdmSymbols(f.mpduDigest.length,f.rfParam.mcs)));
    endrule
    // All signal lifecycle updates share one clock boundary. Endpoints are
    // half-open [start,end); an arrival exactly at an end does not overlap it.
    rule airClock;
        UInt#(32) airNow = clock - 2;
        PhyFsmState next_state = state;
        AirFrame next_current = current;
        UInt#(32) next_endTime = endTime;
        UInt#(32) next_headerTime = headerTime;
        UInt#(32) next_boundary = boundary;
        UInt#(64) next_chunkNoise = chunkNoise;
        Bool next_chunkCollision = chunkCollision;
        Bool next_firstChunk = firstChunk;
        Bool next_headerDone = headerDone;
        Bool next_cca = cca;

        Vector#(NODE_NUM,ActiveSignal) nextSignals = readVReg(signals);
        for (Integer i=0;i<valueOf(NODE_NUM);i=i+1)
            if (nextSignals[i].valid && timeReached(airNow,nextSignals[i].endTime)) nextSignals[i].valid = False;
        Bool newSignal = False;
        PhyEvent arrival = getEmptyPhyEvent;
        UInt#(32) arrivalTime = airNow;
        UInt#(32) arrivalEnd = airNow;
        if (preparedRx.notEmpty) begin
            let t = preparedRx.first; preparedRx.deq;
            arrival = t.frame; arrivalTime = t.arrival;
            arrivalEnd = t.arrival + symbolsToCycles(t.symbols);
`ifdef TRACE_PHY
            $display("PHY signal id=%0d src=%0d pwr=%0d now=%0d end=%0d state=%0d",id,arrival.srcPhyId,arrival.rfParam.power,airNow,arrivalEnd,state);
`endif
            hits[0].send;
            if (t.frame.srcPhyId < fromInteger(valueOf(NODE_NUM)) && t.frame.rfParam.mcs < 8 && !timeReached(airNow,arrivalEnd)) begin
                Bit#(TLog#(NODE_NUM)) source = truncate(t.frame.srcPhyId);
                let prior = nextSignals[source];
                Bool duplicate = prior.valid && prior.tag == t.frame.exchangeId && prior.packet == t.frame.mpduDigest.cacheAddr;
                if (duplicate) hits[6].send;
                else begin
                    nextSignals[source] = ActiveSignal{valid:True,power:t.frame.rfParam.power,linear:t.linear,
                        endTime:arrivalEnd,tag:t.frame.exchangeId,packet:t.frame.mpduDigest.cacheAddr};
                    newSignal = True;
                end
            end
            else hits[7].send;
        end
        Bool receiving = state == PHY_SYNC || state == PHY_RX;
        Bool ended = state != PHY_IDLE && timeReached(airNow,endTime);
        Vector#(NODE_NUM,UInt#(64)) energyTerms = replicate(0);
        Vector#(NODE_NUM,UInt#(64)) interferenceTerms = replicate(0);
        UInt#(5) interferers = 0;
        for (Integer i=0;i<valueOf(NODE_NUM);i=i+1) begin
            let sig = nextSignals[i]; signals[i] <= sig;
            if(sig.valid) begin
                energyTerms[i] = sig.linear;
                if(sig.power > interferenceThreshold) begin
                    interferenceTerms[i] = sig.linear; interferers = interferers+1;
                end
            end
        end
        // Balanced reduction: four adder levels for the 16-source model.
        for(Integer stride=1;stride<valueOf(NODE_NUM);stride=stride*2)
            for(Integer i=0;i<valueOf(NODE_NUM);i=i+2*stride) begin
                energyTerms[i] = energyTerms[i]+energyTerms[i+stride];
                interferenceTerms[i] = interferenceTerms[i]+interferenceTerms[i+stride];
            end
        Bit#(TLog#(NODE_NUM)) ownIndex = truncate(current.srcMacId);
        let own = nextSignals[ownIndex];
        Bool ownEligible = own.valid && own.power > interferenceThreshold;
        UInt#(64) noise = (1 << 24) + interferenceTerms[0] - (ownEligible ? own.linear : 0);
        Bool overlap = interferers > (ownEligible ? 1 : 0);
        next_cca = energyTerms[0] > energyThresholdLinear || (state == PHY_TX && !ended);
        if (receiving) begin
            Bool headerEnd = !headerDone && timeReached(airNow,headerTime);
            if (noise != chunkNoise || overlap != chunkCollision || ended || headerEnd) begin
                UInt#(32) stop = ended ? endTime : airNow;
                errors.request.put(RxChunk{frame:current,interference:chunkNoise,cycles:stop-boundary,
                    header:!headerDone,first:firstChunk,last:ended,headerEnd:headerEnd,
                    collided:chunkCollision,bitModel:bitModel});
                next_boundary = stop; next_chunkNoise = noise; next_chunkCollision = overlap; next_firstChunk = False;
            end
            if (headerEnd) begin next_headerDone = True; next_state = PHY_RX; end
        end
        if (ended) begin
            next_state = PHY_IDLE;
            if (state == PHY_TX) begin txEnd <= True; txTag <= current.exchangeId; end
        end
        // Prefer a ready TX on a truly idle PHY. The emitted channel event and
        // TXSTART share this boundary; airtime starts after all calculations.
        if ((state == PHY_IDLE || ended) && preparedTx.notEmpty && phyTxReqQ.notFull && lowMacTxRespQ.notFull) begin
            let t = preparedTx.first; let f = tpl_1(t); preparedTx.deq;
            PhyEvent e = getEmptyPhyEvent;
            e.srcPhyId=f.srcMacId; e.dstPhyId=f.dstMacId; e.rfParam=f.rfParam;
            e.mpduDigest=f.mpduDigest; e.ppduLen=f.mpduDigest.length; e.exchangeId=f.exchangeId;
            phyTxReqQ.enq(e); lowMacTxRespQ.enq(GenericResp{});
            next_current = f; next_endTime = airNow + symbolsToCycles(tpl_2(t));
            next_state = PHY_TX; txStart <= True; next_cca = True; hits[5].send;
        end
        else if ((state == PHY_IDLE || ended) && newSignal && arrival.rfParam.power > syncThreshold) begin
            MacEvent f = getEmptyMacEvent;
            f.srcMacId=arrival.srcPhyId; f.dstMacId=arrival.dstPhyId;
            f.rfParam=arrival.rfParam; f.mpduDigest=arrival.mpduDigest; f.status=True;
            let air = toAirFrame(f,arrival.exchangeId);
            next_current = air; startedFrame <= air; rxStart <= True; next_state = PHY_SYNC;
            next_endTime = arrivalEnd; next_headerTime = arrivalTime + 20*fromInteger(valueOf(US_CYCLES));
            // Time before the registered timing result is ready is charged to
            // the first chunk, rather than extending the physical frame.
            next_boundary = arrivalTime; next_firstChunk = True; next_headerDone = False;
            Bit#(TLog#(NODE_NUM)) arrivingIndex = truncate(arrival.srcPhyId);
            let arriving = nextSignals[arrivingIndex];
            Bool eligible = arriving.power > interferenceThreshold;
            UInt#(64) n = (1 << 24) + interferenceTerms[0] - (eligible ? arriving.linear : 0);
            Bool c = interferers > (eligible ? 1 : 0);
            next_chunkNoise = n; next_chunkCollision = c; hits[1].send;
        end
        state <= next_state;
        current <= next_current;
        endTime <= next_endTime;
        headerTime <= next_headerTime;
        boundary <= next_boundary;
        chunkNoise <= next_chunkNoise;
        chunkCollision <= next_chunkCollision;
        firstChunk <= next_firstChunk;
        headerDone <= next_headerDone;
        cca <= next_cca;
    endrule
    rule finishDecode;
        let d <- errors.response.get;
        decision <= tagged Valid d;
        if (!d.header) begin
            if (d.success) begin
                let f = d.frame; f.status = True; hits[2].send;
                if (lowMacRxReqQ.notFull) lowMacRxReqQ.enq(f);
                else hits[8].send; // Physical time continues if host delivery is blocked.
            end
            else hits[3].send;
            if (d.collided) hits[4].send;
        end
    endrule
    RWire#(Tuple2#(RegOffset,Bit#(32))) configWrite <- mkRWire;
    rule applyConfig (configWrite.wget matches tagged Valid .w);
        let v = unpack(truncate(tpl_2(w)));
        case(tpl_1(w))
            phy_energy_threshold_off: begin energyThreshold <= v; energyThresholdLinear <= linearPower(v); end
            phy_sync_threshold_off: syncThreshold <= v;
            phy_interference_threshold_off: interferenceThreshold <= v;
            phy_error_model_off: bitModel <= tpl_2(w) == 1;
        endcase
    endrule
    Bool configIdle = state == PHY_IDLE && !cca && !incoming.notEmpty && !preparedRx.notEmpty
        && !lowMacTxReqQ.notEmpty && !preparedTx.notEmpty;
    rule registerAccess;
        let req = phyRegReqQ.first; phyRegReqQ.deq;
        RegAccessResp resp = RegAccessResp{readData:0,error:False};
        Bool writable = False;
        case (req.regOffset)
            phy_fsm_state_off: resp.readData=zeroExtend(pack(state));
            phy_cca_busy_off: resp.readData=zeroExtend(pack(cca));
            rx_power_dbm_off: resp.readData=signExtend(pack(current.rfParam.power));
            fcs_en_h: resp.readData=zeroExtend(pack(isValid(decision) && !fromMaybe(?,decision).header));
            fcs_correct_h: resp.readData=zeroExtend(pack(isValid(decision) && fromMaybe(?,decision).success));
            phy_diag_version_off: resp.readData='h00020000;
            phy_diag_sequence_off: resp.readData=snapshotSequence;
            phy_diag_command_off: begin
                writable=True;
                if (req.writeEnable) begin
                    if (req.writeData == 1) begin
                        for(Integer i=0;i<9;i=i+1) snapshot[i] <= counts[i];
                        snapshotSequence <= snapshotSequence+1;
                    end
                    else if(req.writeData == 2) clearCounters.send;
                    else resp.error=True;
                end
            end
            phy_energy_threshold_off, phy_sync_threshold_off, phy_interference_threshold_off: begin
                writable=True;
                PowerDb v = unpack(truncate(req.writeData));
                if(req.regOffset == phy_energy_threshold_off) begin
                    resp.readData=signExtend(pack(energyThreshold));
                    if(req.writeEnable && configIdle && signExtend(pack(v)) == req.writeData) configWrite.wset(tuple2(req.regOffset,req.writeData));
                end
                if(req.regOffset == phy_sync_threshold_off) begin
                    resp.readData=signExtend(pack(syncThreshold));
                    if(req.writeEnable && configIdle && signExtend(pack(v)) == req.writeData) configWrite.wset(tuple2(req.regOffset,req.writeData));
                end
                if(req.regOffset == phy_interference_threshold_off) begin
                    resp.readData=signExtend(pack(interferenceThreshold));
                    if(req.writeEnable && configIdle && signExtend(pack(v)) == req.writeData) configWrite.wset(tuple2(req.regOffset,req.writeData));
                end
                if(req.writeEnable && (!configIdle || signExtend(pack(v)) != req.writeData)) resp.error=True;
            end
            phy_error_model_off: begin
                writable=True; resp.readData=zeroExtend(pack(bitModel));
                if(req.writeEnable) begin
                    if(configIdle && req.writeData <= 1) configWrite.wset(tuple2(req.regOffset,req.writeData));
                    else resp.error=True;
                end
            end
            default: begin
                if(req.regOffset >= phy_diag_base_off && req.regOffset < phy_diag_base_off+36 && req.regOffset[1:0] == 0)
                    resp.readData=snapshot[(req.regOffset-phy_diag_base_off)>>2];
                else resp.error=True;
            end
        endcase
        if(req.writeEnable && !writable) resp.error=True;
        phyRegRespQ.enq(resp);
    endrule
    interface lowMacTxSrv = toGPServer(lowMacTxReqQ,lowMacTxRespQ);
    interface lowMacRxClt = toGPClient(lowMacRxReqQ,lowMacRxRespQ);
    interface phyTxClt = toGPClient(phyTxReqQ,phyTxRespQ);
    interface phyRegSrv = toGPServer(phyRegReqQ,phyRegRespQ);
    interface perSrv = errors.perSrv;
    interface Server phyRxSrv;
        interface Put request;
            method Action put(PhyEvent e);
                incoming.enq(tuple2(e,clock)); phyRxRespQ.enq(GenericResp{});
            endmethod
        endinterface
        interface response = toGet(phyRxRespQ);
    endinterface
    interface Get getPhyStatus;
        method ActionValue#(PhyStatus) get;
            let p = getEmptyPhyStatus;
            p.state=state; p.cca=cca; p.txStart=txStart; p.txEnd=txEnd; p.txExchangeId=txTag;
            p.rxStart=rxStart; p.rxStartFrame=startedFrame; p.rxFrame=startedFrame;
            if(decision matches tagged Valid .d) begin
                p.rxFrame=d.frame; p.rxHeader=d.header && d.success;
                p.rxEnd=!d.header; p.fcsEn=!d.header; p.fcsCorrect=d.success;
            end
            return p;
        endmethod
    endinterface
endmodule
