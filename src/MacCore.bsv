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

import GetPut::*;
import FIFO::*;
import FIFOF::*;
import LFSR::*;
import ClientServer::*;
import DReg::*;

import Types::*;
import PrimUtils::*;
import CsmaUtils::*;
import FrameTiming::*;
import Vector::*;

/*  
 *  MacEvent --->(PPDU DATA)-----> | MacCore | ---->(RTS,CTS,DATA,ACK)----> |PhyCore| ----> |Channel|
 */

interface MacCore;
    interface MacSrv highMacTxSrv;
    interface MacClt highMacRxClt;

    interface AirSrv lowMacRxSrv;
    interface AirClt lowMacTxClt;

    interface RegAccessSrv macRegSrv;

    interface Put#(PhyStatus) phyStatus;
endinterface

interface Nav_IFC;
    method Action handleFrame(MacEvent frame);
    method Action resetNav();
    method Duration getNavValue();
    method Bool isNavWaiting();
    interface Put#(MacConfig) putmaccfg;
endinterface

module mkNav#(TimeGen usGen, Integer id)(Nav_IFC);
    Reg#(Duration) remaining <- mkReg(0);
    RWire#(Duration) incoming <- mkRWire;
    Reg#(Bool) reset <- mkDReg(False);
    Reg#(Bool) enabled <- mkReg(True);
    RWire#(Bool) cfgUpdate <- mkRWire;
    rule tick;
        Duration n = usGen.get && remaining != 0 ? remaining - 1 : remaining;
        if (incoming.wget matches tagged Valid .v) n = max(n, v);
        let en = fromMaybe(enabled, cfgUpdate.wget);
        remaining <= reset || !en ? 0 : n;
        enabled <= en;
    endrule
    method Action handleFrame(MacEvent f);
        if (f.status && f.dstMacId != fromInteger(id) && f.mpduDigest.duration[15] == 0)
            incoming.wset(f.mpduDigest.duration);
    endmethod
    method Action resetNav(); reset <= True; endmethod
    method Duration getNavValue() = remaining;
    method Bool isNavWaiting() = enabled && remaining != 0;
    interface Put putmaccfg;
        method Action put(MacConfig cfg); cfgUpdate.wset(cfg.navEn); endmethod
    endinterface
endmodule

interface CsmaBackOff_IFC;
    method ContWindowExp currentCW();
    method Action start(Tuple2#(Bool,Bool) option);
    method Action softRst();
    method Action suspendContention();
    method Action incrCW();
    method Action resetCW();
    method Bool available();
    method CsmaState getStatus();
    method Bool done();
    method TimeSlot remainingSlots();
    interface Put#(MacConfig) putmaccfg;
    interface Nav_IFC navctrl;
endinterface

module mkCsmaCaBackOff#(Wire#(PhyStatus) phyStatusWire, TimeGen usGen,
    TimeGen slotGen, Integer id)(CsmaBackOff_IFC);
    Reg#(CsmaState) state <- mkReg(CSMA_IDLE);
    Reg#(MacConfig) cfg <- mkReg(getDefaultMacCfg);
    Reg#(Bool) sifs <- mkReg(False);
    Reg#(Bool) random <- mkReg(False);
    Reg#(Bool) sampled <- mkReg(False);
    Reg#(TimeSlot) slots <- mkReg(0);
    Reg#(UInt#(32)) cycles <- mkReg(0);
    Reg#(Bool) badRx <- mkReg(False);
    PulseWire completedIfs <- mkPulseWire;
    RWire#(Tuple2#(Bool,Bool)) beginWait <- mkRWire;
    PulseWire reset <- mkPulseWire;
    PulseWire suspendRequest <- mkPulseWire;
    Reg#(Bool) savedValid <- mkReg(False);
    Reg#(Bool) savedSampled <- mkReg(False);
    Reg#(TimeSlot) savedSlots <- mkReg(0);
    Reg#(Bool) allow <- mkDReg(False);
    let expBackOffGen <- mkExpBackoffGenerator(id);
    let navController <- mkNav(usGen, id);
    Bool busy = phyStatusWire.cca || (!sifs && navController.isNavWaiting);
    UInt#(32) ifsCycles = zeroExtend(unpack(sifs ? cfg.sifs : (badRx ? cfg.eifs : cfg.difs))) * fromInteger(valueOf(US_CYCLES));
    rule rememberRx;
        if (phyStatusWire.fcsEn) badRx <= !phyStatusWire.fcsCorrect;
        else if (completedIfs) badRx <= False;
    endrule
    rule csmaFSM;
        if (reset) begin
            state <= CSMA_IDLE; sampled <= False; slots <= 0; cycles <= 0; savedValid <= False;
        end
        else if (suspendRequest) begin
            if(random && !sifs) begin
                savedValid <= True; savedSampled <= sampled; savedSlots <= slots;
            end
            state <= CSMA_IDLE; cycles <= 0;
        end
        else case (state)
            CSMA_IDLE: if (beginWait.wget matches tagged Valid .option) begin
                sifs <= tpl_1(option); random <= tpl_2(option);
                if(!tpl_1(option) && tpl_2(option) && savedValid) begin
                    sampled <= savedSampled; slots <= savedSlots; savedValid <= False;
                end
                else sampled <= False;
                cycles <= 0; state <= CSMA_BUSY;
            end
            CSMA_BUSY, CSMA_SUSPEND: if (!busy) begin
                cycles <= 0; state <= CSMA_BACKOFF_IFS;
            end
            CSMA_BACKOFF_IFS: begin
                if (busy) begin cycles <= 0; state <= CSMA_BUSY; end
                else if (cycles + 1 >= ifsCycles) begin
                    if (!sifs) completedIfs.send;
                    cycles <= 0;
                    if (random) begin
                        if (!sampled) begin
                            let n <- expBackOffGen.next.get; slots <= n; sampled <= True;
                        end
                        state <= CSMA_BACKOFF;
                    end
                    else state <= CSMA_DONE;
                end
                else cycles <= cycles + 1;
            end
            CSMA_BACKOFF: begin
                if (busy) begin cycles <= 0; state <= CSMA_SUSPEND; end
                else if (slots == 0) state <= CSMA_DONE;
                else if (cycles + 1 >= zeroExtend(unpack(cfg.slot)) * fromInteger(valueOf(US_CYCLES))) begin
                    slots <= slots - 1; cycles <= 0;
                end
                else cycles <= cycles + 1;
            end
            CSMA_DONE: begin allow <= True; state <= CSMA_IDLE; end
        endcase
    endrule
    method Action start(Tuple2#(Bool,Bool) option); beginWait.wset(option); endmethod
    method Action softRst(); reset.send; endmethod
    method Action suspendContention(); suspendRequest.send; endmethod
    method Action incrCW(); expBackOffGen.incrCW; endmethod
    method Action resetCW(); expBackOffGen.resetCW; endmethod
    method Bool available() = state == CSMA_IDLE;
    method CsmaState getStatus() = state;
    method Bool done() = allow;
    method TimeSlot remainingSlots() = slots;
    method ContWindowExp currentCW() = expBackOffGen.currentCW;
    interface Put putmaccfg;
        method Action put(MacConfig c) if (state == CSMA_IDLE);
            cfg <= c; expBackOffGen.putmaccfg.put(c); navController.putmaccfg.put(c);
        endmethod
    endinterface
    interface navctrl = navController;
endmodule

// The timeout is a response START budget after TXEND. Valid synchronization
// extends to header completion, then a matched header extends to RXEND.
typedef enum { RESP_TX, RESP_START, RESP_HEADER, RESP_COMPLETE } ResponseStage
    deriving(Bits, Eq, FShow);

(* always_enabled = "phyStatus.put" *)
module mkMacDCF#(Integer id)(MacCore);
    FIFOF#(MacEvent) highMacTxReqQ <- mkFIFOF;
    FIFOF#(MacEvent) innerhighMacTxReqQ <- mkSizedFIFOF(valueOf(MAC_FIFOIN_DEPTH));
    FIFOF#(GenericResp) highMacTxRespQ <- mkFIFOF;
    FIFOF#(MacEvent) highMacRxReqQ <- mkFIFOF;
    FIFOF#(GenericResp) highMacRxRespQ <- mkFIFOF;
    FIFOF#(AirFrame) lowMacTxReqQ <- mkFIFOF;
    FIFOF#(GenericResp) lowMacTxRespQ <- mkFIFOF;
    FIFOF#(AirFrame) lowMacRxReqQ <- mkFIFOF;
    FIFOF#(GenericResp) lowMacRxRespQ <- mkFIFOF;
    FIFOF#(AirFrame) lowMacRxYesToMEReqQ <- mkLFIFOF;
    FIFOF#(AirFrame) lowMacRxNotToMEReqQ <- mkLFIFOF;
    FIFOF#(RegAccessReq) macRegReqQ <- mkFIFOF;
    FIFOF#(RegAccessResp) macRegRespQ <- mkFIFOF;
    Reg#(MacConfig) macCfgReg <- mkReg(getDefaultMacCfg);
    Reg#(MacEvent) lasthighMacTxReq <- mkReg(getDefaultMacEvent);
    Wire#(PhyStatus) phyStatusWire <- mkBypassWire;
    Reg#(DcfNextTask) nextTaskReg <- mkReg(NT_IDLE);
    Reg#(DcfState) dcfStateReg <- mkReg(DCF_IDLE);
    Reg#(RetryTime) retransCountReg <- mkReg(0);
    Reg#(UInt#(32)) clock <- mkReg(0);
    Reg#(UInt#(32)) deadline <- mkReg(0);
    Reg#(ResponseStage) responseStage <- mkReg(RESP_TX);
    Reg#(Bit#(32)) exchangeId <- mkReg(0);
    Reg#(Duration) reservedRts <- mkReg(0);
    TimeGen usGen <- mkUsGen(valueOf(US_CYCLES));
    TimeGen slotGen <- mkSlotGen(usGen, macCfgReg);
    let backOffFsm <- mkCsmaCaBackOff(phyStatusWire, usGen, slotGen, id);
    Reg#(Bit#(32)) cfgGeneration <- mkReg(0);
    Reg#(TimeUs) cfgQuietUs <- mkReg(0);
    Reg#(UInt#(32)) mac_fifoin_count <- mkReg(0);
    Vector#(12, PulseWire) hits <- replicateM(mkPulseWire);
    Vector#(12, Reg#(Bit#(32))) counts <- replicateM(mkReg(0));
    Vector#(12, Reg#(Bit#(32))) snapshot <- replicateM(mkReg(0));
    PulseWire clearCounters <- mkPulseWire;
    Reg#(Bit#(32)) snapshotSequence <- mkReg(0);
    rule countEvents;
        clock <= clock + 1;
        for (Integer i=0; i<12; i=i+1)
            counts[i] <= clearCounters ? 0 : counts[i] + (hits[i] ? 1 : 0);
        mac_fifoin_count <= mac_fifoin_count + (hits[0] ? 1 : 0) - (hits[7] ? 1 : 0);
    endrule
    rule countCrc (phyStatusWire.fcsEn && !phyStatusWire.fcsCorrect); hits[11].send; endrule
    Bool cfgQueuesIdle = dcfStateReg == DCF_IDLE && backOffFsm.available
        && !highMacTxReqQ.notEmpty && !innerhighMacTxReqQ.notEmpty
        && !lowMacTxReqQ.notEmpty && !lowMacRxReqQ.notEmpty
        && !lowMacRxYesToMEReqQ.notEmpty && !lowMacRxNotToMEReqQ.notEmpty
        && phyStatusWire.state == PHY_IDLE && !phyStatusWire.cca
        && !backOffFsm.navctrl.isNavWaiting;
    rule trackConfigQuiet;
        if (!cfgQueuesIdle) cfgQuietUs <= 0;
        else if (usGen.get && cfgQuietUs < macCfgReg.timeout) cfgQuietUs <= cfgQuietUs + 1;
    endrule
    Bool cfgCanApply = cfgQueuesIdle && (nextTaskReg == NT_IDLE ||
        (nextTaskReg == NT_RECV_DATA && cfgQuietUs >= macCfgReg.timeout));
    rule phyHandShake; lowMacTxRespQ.deq; endrule
    rule highMacHandShake; highMacRxRespQ.deq; endrule
    rule txRegcopy;
        let f = highMacTxReqQ.first; highMacTxReqQ.deq;
        innerhighMacTxReqQ.enq(f); hits[0].send;
    endrule
    rule rxRegcopy;
        let f = lowMacRxReqQ.first;
        if (f.status) begin
            if (isMyFrame(id, f.dstMacId)) lowMacRxYesToMEReqQ.enq(f);
            else lowMacRxNotToMEReqQ.enq(f);
        end
        lowMacRxReqQ.deq; lowMacRxRespQ.enq(GenericResp{});
    endrule
    rule updateNAV;
        let f = lowMacRxNotToMEReqQ.first; lowMacRxNotToMEReqQ.deq;
        if (isRtsFrame(f.mpduDigest) || isCtsFrame(f.mpduDigest) || isDataFrame(f.mpduDigest))
            backOffFsm.navctrl.handleFrame(toMacEvent(f));
    endrule
    (* descending_urgency = "dcfFsmIdle, trackConfigQuiet" *)
    rule dcfFsmIdle (dcfStateReg == DCF_IDLE && backOffFsm.available &&
        (lowMacRxYesToMEReqQ.notEmpty || (innerhighMacTxReqQ.notEmpty && nextTaskReg != NT_RECV_DATA) ||
        (nextTaskReg == NT_RECV_DATA && cfgQuietUs >= macCfgReg.timeout)));
        if (lowMacRxYesToMEReqQ.notEmpty) begin
            let f = lowMacRxYesToMEReqQ.first;
            if (isDataFrame(f.mpduDigest) || isRtsFrame(f.mpduDigest)) begin
                nextTaskReg <= isDataFrame(f.mpduDigest) ? NT_SEND_ACK : NT_SEND_CTS;
                dcfStateReg <= DCF_WAIT_BACKOFF; backOffFsm.start(tuple2(True, False));
                if (isDataFrame(f.mpduDigest)) begin highMacRxReqQ.enq(toMacEvent(f)); hits[8].send; end
            end
            else begin lowMacRxYesToMEReqQ.deq; hits[9].send; end
        end
        else if (innerhighMacTxReqQ.notEmpty && nextTaskReg != NT_RECV_DATA) begin
            let f = innerhighMacTxReqQ.first;
            Bool afterCts = nextTaskReg == NT_SEND_DATA;
            backOffFsm.start(tuple2(afterCts, !afterCts));
            nextTaskReg <= !afterCts && f.mpduDigest.length > macCfgReg.rtsThreshold ? NT_SEND_RTS : NT_SEND_DATA;
            dcfStateReg <= DCF_WAIT_BACKOFF;
            lasthighMacTxReq <= f;
            reservedRts <= rtsDuration(f, macCfgReg);
            if (!afterCts) exchangeId <= exchangeId + 1;
        end
        else if (nextTaskReg == NT_RECV_DATA && cfgQuietUs >= macCfgReg.timeout) nextTaskReg <= NT_IDLE;
    endrule
    // A frame addressed to this node can arrive while it contends. Suspend our
    // own attempt and serve its SIFS response; retry the queued attempt later.
    rule interruptBackoff (dcfStateReg == DCF_WAIT_BACKOFF &&
        (nextTaskReg == NT_SEND_RTS || nextTaskReg == NT_SEND_DATA) && !backOffFsm.done);
        let f = lowMacRxYesToMEReqQ.first;
        if (isDataFrame(f.mpduDigest) || isRtsFrame(f.mpduDigest)) begin
            backOffFsm.suspendContention; dcfStateReg <= DCF_IDLE; nextTaskReg <= NT_IDLE;
        end
        else begin lowMacRxYesToMEReqQ.deq; hits[9].send; end
    endrule
    rule dcfWaitBackOff (dcfStateReg == DCF_WAIT_BACKOFF && backOffFsm.done);
        if (nextTaskReg == NT_SEND_RTS || nextTaskReg == NT_SEND_DATA) begin
            let f = innerhighMacTxReqQ.first;
            if (nextTaskReg == NT_SEND_RTS) begin
                f = setRtsFrame(f); f.rfParam.mcs = macCfgReg.controlMcs;
                f.mpduDigest.duration = reservedRts; nextTaskReg <= NT_RECV_CTS; hits[2].send;
            end
            else begin f.mpduDigest.duration = dataDuration(macCfgReg); nextTaskReg <= NT_RECV_ACK; hits[1].send; end
            lowMacTxReqQ.enq(toAirFrame(f, exchangeId));
            responseStage <= RESP_TX; dcfStateReg <= DCF_RECV_CTSACK;
        end
        else begin
            let air = lowMacRxYesToMEReqQ.first; lowMacRxYesToMEReqQ.deq;
            let f = toMacEvent(air); f.rfParam.power = lasthighMacTxReq.rfParam.power;
            if (nextTaskReg == NT_SEND_CTS) begin
                f = setCtsFrame(id, f); f.mpduDigest.duration = ctsDuration(f.mpduDigest.duration, macCfgReg);
                nextTaskReg <= NT_RECV_DATA;
            end
            else begin f = setAckFrame(id, f); f.mpduDigest.duration = 0; nextTaskReg <= NT_IDLE; end
            f.rfParam.mcs = macCfgReg.controlMcs;
            lowMacTxReqQ.enq(toAirFrame(f, air.exchangeId)); dcfStateReg <= DCF_IDLE;
        end
    endrule
    function Bool matchesResponse(AirFrame f);
        return f.dstMacId == fromInteger(id) && f.srcMacId == lasthighMacTxReq.dstMacId
            && f.exchangeId == exchangeId && f.mpduDigest.cacheAddr == lasthighMacTxReq.mpduDigest.cacheAddr
            && ((nextTaskReg == NT_RECV_CTS && isCtsFrame(f.mpduDigest)) ||
                (nextTaskReg == NT_RECV_ACK && isAckFrame(f.mpduDigest)));
    endfunction
    rule dcfRecvCtsAck (dcfStateReg == DCF_RECV_CTSACK);
        Bool completed = False;
        Bool failed = responseStage != RESP_TX && timeReached(clock, deadline);
        if (responseStage == RESP_TX) begin
            if (phyStatusWire.txEnd && phyStatusWire.txExchangeId == exchangeId) begin
                responseStage <= RESP_START;
                deadline <= clock + zeroExtend(unpack(macCfgReg.timeout)) * fromInteger(valueOf(US_CYCLES));
            end
        end
        else begin
            if (responseStage == RESP_START && !timeReached(clock,deadline+1) && phyStatusWire.rxStart && matchesResponse(phyStatusWire.rxStartFrame)) begin
                responseStage <= RESP_HEADER; failed = False;
                deadline <= clock + 21 * fromInteger(valueOf(US_CYCLES));
            end
            if (responseStage == RESP_HEADER && !timeReached(clock,deadline+1) && phyStatusWire.rxHeader && matchesResponse(phyStatusWire.rxFrame)) begin
                responseStage <= RESP_COMPLETE; failed = False;
                // Full-frame bound includes decode pipeline and queue latency.
                deadline <= clock + symbolsToCycles(ofdmSymbols(phyStatusWire.rxFrame.mpduDigest.length,
                    phyStatusWire.rxFrame.rfParam.mcs)) + 64;
            end
            if (lowMacRxYesToMEReqQ.notEmpty) begin
                let f = lowMacRxYesToMEReqQ.first; lowMacRxYesToMEReqQ.deq;
                if (responseStage == RESP_COMPLETE && !failed && matchesResponse(f)) begin
                    completed = True; dcfStateReg <= DCF_IDLE;
                    if (nextTaskReg == NT_RECV_CTS) nextTaskReg <= NT_SEND_DATA;
                    else begin
                        nextTaskReg <= NT_IDLE; retransCountReg <= 0; backOffFsm.resetCW;
                        innerhighMacTxReqQ.deq; highMacTxRespQ.enq(GenericResp{}); hits[3].send; hits[7].send;
                    end
                end
                else hits[9].send;
            end
            if (failed && !completed) begin
                if (nextTaskReg == NT_RECV_CTS) hits[4].send; else hits[5].send;
                dcfStateReg <= DCF_IDLE; nextTaskReg <= NT_IDLE;
                if (retransCountReg < macCfgReg.retryLimit) begin retransCountReg <= retransCountReg + 1; backOffFsm.incrCW; end
                else begin
                    retransCountReg <= 0; backOffFsm.resetCW; innerhighMacTxReqQ.deq;
                    highMacTxRespQ.enq(GenericResp{}); hits[6].send; hits[7].send;
                end
            end
        end
    endrule
    rule readMacRegisters (!macRegReqQ.first.writeEnable);
        let req = macRegReqQ.first; macRegReqQ.deq;
        RegAccessResp resp = RegAccessResp{readData:0,error:False};
        case (req.regOffset)
            mac_slot_time_off: resp.readData = zeroExtend(macCfgReg.slot);
            mac_sifs_off: resp.readData = zeroExtend(macCfgReg.sifs);
            mac_difs_off: resp.readData = zeroExtend(macCfgReg.difs);
            mac_eifs_off: resp.readData = zeroExtend(macCfgReg.eifs);
            mac_sig_time_off: resp.readData = zeroExtend(macCfgReg.sigTime);
            mac_ofdm_symbol_off: resp.readData = zeroExtend(macCfgReg.ofdmSymbolTime);
            mac_max_num_off: resp.readData = zeroExtend(macCfgReg.maxNum);
            mac_phy_delay_off: resp.readData = zeroExtend(macCfgReg.phyDelayTime);
            mac_timeout_off: resp.readData = zeroExtend(macCfgReg.timeout);
            mac_cw_min_off: resp.readData = zeroExtend(macCfgReg.cwMin);
            mac_cw_max_off: resp.readData = zeroExtend(macCfgReg.cwMax);
            mac_rts_thresh_off: resp.readData = zeroExtend(macCfgReg.rtsThreshold);
            mac_retry_limit_off: resp.readData = zeroExtend(macCfgReg.retryLimit);
            nav_en_h_off: resp.readData = zeroExtend(pack(macCfgReg.navEn));
            txop_en_h_off: resp.readData = zeroExtend(pack(macCfgReg.txopEn));
            filter_en_h_off: resp.readData = zeroExtend(pack(macCfgReg.filterEn));
            mac_backoff_state_off: resp.readData = zeroExtend(pack(backOffFsm.getStatus));
            mac_dcf_state_off: resp.readData = zeroExtend(pack(dcfStateReg));
            mac_fifoin_depth_off: resp.readData = fromInteger(valueOf(MAC_FIFOIN_DEPTH));
            mac_fifoin_count_off: resp.readData = pack(mac_fifoin_count);
            mac_cfg_generation_off: resp.readData = cfgGeneration;
            mac_us_cycles_off: resp.readData = fromInteger(valueOf(US_CYCLES));
            mac_cw_exp_off: resp.readData = zeroExtend(backOffFsm.currentCW);
            mac_nav_remaining_off: resp.readData = zeroExtend(backOffFsm.navctrl.getNavValue);
            mac_control_mcs_off: resp.readData = zeroExtend(macCfgReg.controlMcs);
            mac_backoff_seed_off: resp.readData = zeroExtend(macCfgReg.backoffSeed);
            mac_diag_version_off: resp.readData = 'h00020000;
            mac_diag_sequence_off: resp.readData = snapshotSequence;
            mac_response_stage_off: resp.readData = zeroExtend(pack(responseStage));
            mac_exchange_id_off: resp.readData = exchangeId;
            mac_nav_reset_off: resp.readData = 0;
            mac_diag_command_off: resp.readData = 0;
            default: begin
                if (req.regOffset >= mac_diag_base_off && req.regOffset < mac_diag_base_off+48 && req.regOffset[1:0] == 0)
                    resp.readData=snapshot[(req.regOffset-mac_diag_base_off)>>2];
                else resp.error=True;
            end
        endcase
        macRegRespQ.enq(resp);
    endrule

    // 寄存器访问处理规则
    (* descending_urgency = "handleMacRegAccess, trackConfigQuiet, updateNAV" *)
    (* descending_urgency = "handleMacRegAccess, backOffFsm.csmaFSM" *)
    (* descending_urgency = "handleMacRegAccess, dcfFsmIdle, dcfWaitBackOff, dcfRecvCtsAck" *)
    // Stop traffic and drain outstanding exchanges before configuration writes.
    // Read requests remain available during traffic; a queued write waits for
    // quiescence. The write response means all consumers have applied the value.
    rule handleMacRegAccess (macRegReqQ.first.writeEnable && (cfgCanApply || macRegReqQ.first.regOffset == mac_diag_command_off || (macRegReqQ.first.regOffset == mac_nav_reset_off && dcfStateReg == DCF_IDLE)));
        let req = macRegReqQ.first;
        macRegReqQ.deq;
        RegAccessResp resp = RegAccessResp{readData: 0, error: False};

        MacConfig nextCfg = macCfgReg;
        Bool writable = False;
        Bit#(32) maxWrite = 65535;

        // 寄存器访问逻辑
        case (req.regOffset)
            // MAC 配置寄存器 (可修改)
            mac_slot_time_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.slot = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.slot);
            end
            mac_sifs_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.sifs = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.sifs);
            end
            mac_difs_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.difs = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.difs);
            end
            mac_eifs_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.eifs = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.eifs);
            end
            mac_sig_time_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.sigTime = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.sigTime);
            end
            mac_ofdm_symbol_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.ofdmSymbolTime = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.ofdmSymbolTime);
            end
            mac_max_num_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.maxNum = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.maxNum);
            end
            mac_phy_delay_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.phyDelayTime = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.phyDelayTime);
            end
            mac_timeout_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.timeout = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.timeout);
            end
            mac_cw_min_off: begin
                writable = True; maxWrite = 10;
                if (req.writeEnable) nextCfg.cwMin = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.cwMin);
            end
            mac_cw_max_off: begin
                writable = True; maxWrite = 10;
                if (req.writeEnable) nextCfg.cwMax = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.cwMax);
            end
            mac_rts_thresh_off: begin
                writable = True; maxWrite = 65535;
                if (req.writeEnable) nextCfg.rtsThreshold = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.rtsThreshold);
            end
            mac_retry_limit_off: begin
                writable = True; maxWrite = 15;
                if (req.writeEnable) nextCfg.retryLimit = truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.retryLimit);
            end
            nav_en_h_off: begin
                writable = True; maxWrite = 1;
                if (req.writeEnable) nextCfg.navEn = unpack(truncate(req.writeData[0]));
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(pack(macCfgReg.navEn));

            end
            txop_en_h_off: begin
                writable = True; maxWrite = 1;
                if (req.writeEnable) nextCfg.txopEn = unpack(truncate(req.writeData[0]));
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(pack(macCfgReg.txopEn));
            end
            filter_en_h_off: begin
                writable = True; maxWrite = 1;
                if (req.writeEnable) nextCfg.filterEn = unpack(truncate(req.writeData[0]));
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(pack(macCfgReg.filterEn));
            end
            
            // MAC 状态寄存器 (仅查询)
            mac_backoff_state_off: begin
                resp.readData = zeroExtend(pack(backOffFsm.getStatus));
            end
            mac_dcf_state_off: begin
                resp.readData = zeroExtend(pack(dcfStateReg));
            end
            mac_fifoin_depth_off: begin
                resp.readData = fromInteger(valueOf(MAC_FIFOIN_DEPTH));
            end
            mac_fifoin_count_off: begin
                resp.readData = zeroExtend(pack(mac_fifoin_count));
            end
            
            mac_cfg_generation_off: resp.readData = cfgGeneration;
            mac_us_cycles_off: resp.readData = fromInteger(valueOf(US_CYCLES));
            mac_cw_exp_off: resp.readData = zeroExtend(backOffFsm.currentCW);
            mac_nav_remaining_off: resp.readData = zeroExtend(backOffFsm.navctrl.getNavValue);

            mac_control_mcs_off: begin
                writable = True; maxWrite = 7;
                if (req.writeEnable) nextCfg.controlMcs = truncate(req.writeData);
                resp.readData = zeroExtend(macCfgReg.controlMcs);
            end
            mac_backoff_seed_off: begin
                writable = True;
                if (req.writeEnable) nextCfg.backoffSeed = truncate(req.writeData);
                resp.readData = zeroExtend(macCfgReg.backoffSeed);
            end
            mac_diag_version_off: resp.readData = 'h00020000;
            mac_diag_sequence_off: resp.readData = snapshotSequence;
            mac_response_stage_off: resp.readData = zeroExtend(pack(responseStage));
            mac_exchange_id_off: resp.readData = exchangeId;
            mac_nav_reset_off: begin
                if (req.writeEnable && req.writeData == 1) backOffFsm.navctrl.resetNav;
                else if (req.writeEnable) resp.error = True;
            end
            mac_diag_command_off: begin
                if (req.writeEnable) begin
                    if (req.writeData == 1) begin
                        for (Integer i=0; i<12; i=i+1) snapshot[i] <= counts[i];
                        snapshotSequence <= snapshotSequence + 1;
                    end
                    else if (req.writeData == 2) clearCounters.send;
                    else resp.error = True;
                end
            end
            default: begin
                if (req.regOffset >= mac_diag_base_off && req.regOffset < mac_diag_base_off + 48 && req.regOffset[1:0] == 0)
                    resp.readData = snapshot[(req.regOffset - mac_diag_base_off) >> 2];
                else resp.error = True;

            end
        endcase
        
        if (req.writeEnable && req.regOffset != mac_diag_command_off && req.regOffset != mac_nav_reset_off) begin
            resp.error = resp.error || !writable || req.writeData > maxWrite
                || nextCfg.slot == 0 || nextCfg.cwMin > nextCfg.cwMax
                || nextCfg.cwMax > 10 || nextCfg.backoffSeed == 0 || nextCfg.timeout == 0;
            if (!resp.error) begin
                macCfgReg <= nextCfg;
                backOffFsm.putmaccfg.put(nextCfg);
                cfgGeneration <= cfgGeneration + 1;
            end
        end
        macRegRespQ.enq(resp);
    endrule


    interface highMacTxSrv = toGPServer(highMacTxReqQ, highMacTxRespQ);
    interface highMacRxClt = toGPClient(highMacRxReqQ, highMacRxRespQ);
    interface lowMacTxClt  = toGPClient(lowMacTxReqQ, lowMacTxRespQ);
    interface lowMacRxSrv  = toGPServer(lowMacRxReqQ, lowMacRxRespQ);

    interface macRegSrv    = toGPServer(macRegReqQ, macRegRespQ);


    interface Put phyStatus;
        method Action put(PhyStatus phyStatus);
            phyStatusWire <= phyStatus;
        endmethod
    endinterface


endmodule
