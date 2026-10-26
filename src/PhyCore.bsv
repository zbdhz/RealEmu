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
import FIFO::*;
import FIFOF::*;
import ClientServer::*;
import DReg::*;
import BUtils ::*;
import RegFile::*;
import BRAM::*;

import LFSR::*;
import Divide::*;

import ROM::*;
import Types::*;
import PrimUtils::*;


// T02: 仅给正在计算的时长/查表携带标记，不增加活动干扰表或改动外部事件格式。
typedef struct {
    Bool tx;
    Bool strong;
    UInt#(32) started;
} PhyTimingTag deriving (Bits, Eq, FShow);
typedef struct {
    PhyTimingTag tag;
    UInt#(16) length;
    Mcs mcs;
} PhyTimingReq deriving (Bits, FShow);
typedef struct {
    Bool payload;
    UInt#(32) epoch;
    Mcs mcs;
    PowerDb power;
} PhyLookupTag deriving (Bits, FShow);

function UInt#(18) phyNdbps(Mcs mcs);
    case (mcs)
        0: return 24; 1: return 36; 2: return 48; 3: return 72;
        4: return 96; 5: return 144; 6: return 192; 7: return 216;
        default: return 24; // 非法 MCS 不能形成除零；RX 最终会拒绝非法速率。
    endcase
endfunction

interface PhyCore;
    interface MacSrv lowMacTxSrv;
    interface MacClt lowMacRxClt;

    interface PhySrv phyRxSrv;
    interface PhyClt phyTxClt;

    interface PerSrv perSrv;

    // interface PhyStatusSrv phyStatusSrv;
    interface Get#(PhyStatus) getPhyStatus;
    // method PhyStatus getPhyStatus;
    
    interface RegAccessSrv phyRegSrv;
endinterface

///============================= phyState =====================================
/// Int#(12) powerdB Q6.5       UInt#(32) powerLinear U24.8
///============================================================================
// (* synthesize *)
module mkPhyYansWifi#(Integer id)(PhyCore);
    FIFOF#(MacEvent)    lowMacTxReqQ      <- mkFIFOF;
    FIFOF#(GenericResp) lowMacTxRespQ     <- mkFIFOF;
    FIFOF#(MacEvent)    lowMacRxReqQ      <- mkFIFOF;
    FIFOF#(GenericResp) lowMacRxRespQ     <- mkFIFOF;

    FIFOF#(PhyEvent)    phyTxReqQ         <- mkFIFOF;
    FIFOF#(GenericResp) phyTxRespQ        <- mkFIFOF;
    // 入站时记录到达周期，后续排队/除法延迟不能重新延长空口时间。
    Reg#(UInt#(32)) phyCycle <- mkReg(0);
    rule countPhyCycle;
        phyCycle <= phyCycle + 1;
    endrule
    FIFOF#(Tuple2#(UInt#(32), PhyEvent)) phyRxReqQ <- mkFIFOF;
    FIFOF#(PhyTimingReq) txTimingQ <- mkFIFOF;
    FIFOF#(PhyTimingReq) rxTimingQ <- mkFIFOF;
    Reg#(UInt#(32)) rxArrivalReg <- mkReg(0);
    Reg#(UInt#(32)) currentRxEpoch <- mkReg(0);
    Reg#(UInt#(32)) currentTxEpoch <- mkReg(0);
    FIFOF#(PhyLookupTag) lookupReqQ <- mkFIFOF;
    FIFOF#(PhyLookupTag) searchTags <- mkFIFOF;
    FIFOF#(PhyLookupTag) perTags <- mkFIFOF;
    FIFOF#(Tuple2#(PhyLookupTag, UInt#(16))) perResults <- mkFIFOF;
    Reg#(Bool) syncLookupSent <- mkReg(False);
    Reg#(Bool) dataLookupSent <- mkReg(False);
    Reg#(Bool) syncPerReady <- mkReg(False);
    Reg#(Bool) dataPerReady <- mkReg(False);
    Reg#(UInt#(16)) syncPerValue <- mkReg(0);
    Reg#(UInt#(16)) dataPerValue <- mkReg(0);
    FIFOF#(GenericResp) phyRxRespQ        <- mkFIFOF;

    // FIFOF#(PhyStatusReq) phyStatusReqQ     <- mkFIFOF;
    // FIFOF#(PhyStatusRes) phyStatusRespQ    <- mkFIFOF;
    
    // 寄存器访问接口
    FIFOF#(RegAccessReq)  phyRegReqQ  <- mkFIFOF;
    FIFOF#(RegAccessResp) phyRegRespQ <- mkFIFOF;

    //Per曲线动态加载访问接口
    FIFOF#(PerCfg)      perTxReqQ   <- mkFIFOF;
    FIFOF#(GenericResp) perTxRespQ  <- mkFIFOF;

    // T01: 保留单时钟域；所有微秒换算只引用 Types 中的同一常量。
    UInt#(32) clkFreq = fromInteger(valueOf(US_CYCLES));

    UInt#(32)  syncTime     = 20 * clkFreq;  
    UInt#(32)  noisePower   = 256; //1mW   
    Int#(12)   lowSNR       = -160;   
    Int#(12)   highSNR      = 960;
    Int#(12)   threash      =-960;   // threash = -30dBm  
    // 碰撞模型对齐 ns-3: CS(Clear Sense)能量门限, 4dBm。
    // 落在隐藏对收功率 74(d=1023,2.3dBm) 与最远正常对 186(d=682,5.8dBm) 之间,
    // 用于: ①CCA 忙判定门控 ②SYNC 进入门限 ③碰撞干扰有效性判据
    Int#(12)   csThreash    = 128;
    //---------------------------
    //reg wire 
    //---------------------------
    Reg#(Bool)       txBeginReg         <- mkReg(False);
    // D01/D02: 完成脉冲独立清零，后续 TX 的信道队列背压不能把旧 txEnd 拉长。
    Reg#(Bool)       txEndReg           <- mkDReg(False);
    Reg#(Bool)       rxBeginReg         <- mkReg(False);
    Reg#(Bool)       rxEndReg           <- mkReg(False);

    Reg#(Int#(12))   currentPowerReg    <- mkReg(0);     
    Reg#(Mcs)        currentMcsReg      <- mkReg(0);
    Reg#(UInt#(16))  currentLenReg      <- mkReg(0);
    Reg#(MpduDigest) currentMpduDigest  <- mkReg(getEmptyMpduDigest);

    Reg#(Bool)       rxValidReg         <- mkDReg(False); 
    Reg#(Int#(12))   rxPowerReg         <- mkReg(0);   
    Reg#(Mcs)        rxMcsReg           <- mkReg(0);
    Reg#(UInt#(16))  rxLenReg           <- mkReg(0);
    Reg#(MpduDigest) rxMpduDigest       <- mkReg(getEmptyMpduDigest); 
    
    
    Reg#(PhyFsmState)stateReg           <- mkReg(PHY_IDLE); 
    Wire#(Bool)      ccaBusyReg         <- mkDWire(False); 
    // 碰撞标记: 正在收帧时又来一个过 CS 门限的新帧 -> 当前帧判废 (对齐 ns-3 无 capture 双败)
    Reg#(Bool)       collideReg         <- mkReg(False);
    Reg#(Bool)       syncCrcReg         <- mkDReg(False);
    Reg#(Bool)       syncEndReg         <- mkDReg(False);
    Reg#(Bool)       crcReg             <- mkDReg(False);

    Reg#(Bit#(16))   randomValueReg     <- mkReg(0);

    Reg#(Bit#(DEV_ID_WIDTH))   currentSrcipReg   <- mkReg(0);
    Reg#(Bit#(DEV_ID_WIDTH))   currentDstipReg   <- mkReg(0);
    Reg#(Bit#(DEV_ID_WIDTH))   rxSrcipReg        <- mkReg(0);
    Reg#(Bit#(DEV_ID_WIDTH))   rxDstipReg        <- mkReg(0);

    //---------------------------
    // timer 
    //---------------------------
    Wire#(Bool) txTimeValid <- mkDWire(False);
    Wire#(Bool) rxTimeValid <- mkDWire(False);
    Wire#(Bool) energyTimeValid <- mkDWire(False);
    Wire#(UInt#(32)) txRemaining <- mkDWire(0);
    Wire#(UInt#(32)) rxRemaining <- mkDWire(0);
    Wire#(UInt#(32)) energyRemaining <- mkDWire(0);

    Reg#(UInt#(32))     rxTimerReg          <- mkReg(0);     
    Reg#(UInt#(32))     syncTimerReg        <- mkReg(0);     
    Reg#(UInt#(32))     txTimerReg          <- mkReg(clkFreq * 20);   
    Reg#(UInt#(32))     ccaTimerReg         <- mkReg(0);  

    //---------------------
    //FIFOF
    //---------------------
    rule handshakeTx;
        phyTxRespQ.deq;
    endrule

    rule handshakeRx;
       lowMacRxRespQ.deq;
    endrule

    rule handlePhyRxReqQ;
        if (phyRxReqQ.notEmpty) begin
            let {arrived, phyRxpkt} = phyRxReqQ.first;
            rxTimingQ.enq(PhyTimingReq{
                tag: PhyTimingTag{tx: False, strong: phyRxpkt.rfParam.power > csThreash, started: arrived},
                length: unpack(phyRxpkt.ppduLen), mcs: phyRxpkt.rfParam.mcs});
            rxArrivalReg <= arrived;
            phyRxReqQ.deq;
            phyRxRespQ.enq(GenericResp{});

            rxValidReg  <= True;
            rxSrcipReg  <= phyRxpkt.srcPhyId;
            rxDstipReg  <= phyRxpkt.dstPhyId;
            rxMcsReg    <= phyRxpkt.rfParam.mcs;
            rxPowerReg  <= phyRxpkt.rfParam.power;
            rxLenReg    <= unpack(pack(phyRxpkt.ppduLen));
            rxMpduDigest<= phyRxpkt.mpduDigest;
            //暂存数据包，设定标志位，等待逻辑运算通过后传输
            $display("[%8d ns] phyRxReqQ.deq;,mypyhid:%d,srcPhyid:%d,dstPhyId:%d",$time, id,phyRxpkt.srcPhyId,phyRxpkt.dstPhyId);
        end
    endrule

    // T02: CCA 按事件自身强弱和原始到达时间更新，不读取返回时的 RX 功率/PHY 状态。
    rule updateccaBusyReg;
        ccaBusyReg <= (ccaTimerReg > 0) || stateReg == PHY_TX
                      || stateReg == PHY_SYNC || stateReg == PHY_RX;
        UInt#(32) remaining = ccaTimerReg > 0 ? ccaTimerReg - 1 : 0;
        UInt#(32) age = phyCycle - rxArrivalReg;
        // 先覆盖前导期，消除时长计算尚未返回时的 CCA 空窗。
        if (rxValidReg && rxPowerReg > csThreash && age < syncTime)
            remaining = max(remaining, syncTime - age - 1);
        if (energyTimeValid && energyRemaining > 0)
            remaining = max(remaining, energyRemaining - 1);
        ccaTimerReg <= remaining;
    endrule

    // 同拍 TX/RX 分别保存在原子接受路径的队列中，共用原除法器；没有优先级丢事件。
    Server#(Tuple2#(UInt#(36), UInt#(18)), Tuple2#(UInt#(18), UInt#(18))) divider <- mkDivider(1);
    FIFOF#(PhyTimingTag) timingTags <- mkSizedFIFOF(32);
    FIFOF#(Tuple2#(PhyTimingTag, UInt#(18))) symbolsQ <- mkFIFOF;
    FIFOF#(Tuple2#(PhyTimingTag, UInt#(32))) payloadCyclesQ <- mkFIFOF;
    FIFOF#(Tuple2#(PhyTimingTag, UInt#(32))) totalCyclesQ <- mkFIFOF;
    rule feed_operation;
        let request = txTimingQ.notEmpty ? txTimingQ.first : rxTimingQ.first;
        if (txTimingQ.notEmpty) txTimingQ.deq;
        else rxTimingQ.deq;
        UInt#(36) bits = (zeroExtend(request.length) << 3) + 22;
        divider.request.put(tuple2(bits, phyNdbps(request.mcs)));
        timingTags.enq(request.tag);
    endrule
    rule divideResult;
        let {quotient, remainder} <- divider.response.get;
        symbolsQ.enq(tuple2(timingTags.first, quotient + (remainder != 0 ? 1 : 0)));
        timingTags.deq;
    endrule
    rule scalePayloadCycles;
        let {tag, symbols} = symbolsQ.first;
        // 乘法单独落寄存级，切断旧 divider -> DSP -> CCA 组合关键路径。
        payloadCyclesQ.enq(tuple2(tag, zeroExtend(symbols) * (4 * clkFreq)));
        symbolsQ.deq;
    endrule
    rule addPreambleCycles;
        let {tag, payload} = payloadCyclesQ.first;
        totalCyclesQ.enq(tuple2(tag, payload + syncTime));
        payloadCyclesQ.deq;
    endrule
    rule publishDuration;
        let {tag, total} = totalCyclesQ.first;
        totalCyclesQ.deq;
        UInt#(32) elapsed = phyCycle - tag.started; // 32位模减；合法帧远小于半个回绕周期。
        UInt#(32) remaining = total > elapsed ? total - elapsed : 0;
        if (tag.tx && tag.started == currentTxEpoch) begin
            txTimeValid <= True;
            txRemaining <= remaining;
        end
        if (!tag.tx && tag.started == currentRxEpoch) begin
            rxTimeValid <= True;
            rxRemaining <= remaining;
        end
        if (tag.tx || tag.strong) begin
            energyTimeValid <= True;
            energyRemaining <= remaining;
        end
    endrule

    //---------------------------
    // 碰撞检测(并入 handlePhyState 的 SYNC/RX 分支):
    // 接收中又来一个过 CS 门限的新帧 -> collideReg 置位, 当前帧判废。
    // 新帧自身不重同步(状态机忙被丢弃) => 两帧全败, 对齐 ns-3 无 capture 碰撞语义。
    // 发送方走既有 timeout 重传路径, MacCore 零改动。
    //---------------------------

    //---------------------------
    // stateReg
    //---------------------------
    rule handlePhyState;
        // RX timer 代表整帧剩余周期，跨 SYNC/RX 连续扣减，不因查表/状态切换重装时长。
        if (stateReg == PHY_SYNC || stateReg == PHY_RX) begin
            if (rxBeginReg && rxTimeValid) begin
                rxTimerReg <= rxRemaining > 0 ? rxRemaining - 1 : 0;
                rxBeginReg <= False;
            end
            else if (!rxBeginReg && rxTimerReg > 0) rxTimerReg <= rxTimerReg - 1;
        end
        case (stateReg)
            PHY_IDLE: begin
                rxEndReg <= False;
                // D01: 忙时请求留在原 FIFO；接受、信道发布和进入 TX 必须同拍完成。
                // 已到达的强 RX 优先；隐藏弱帧不能仅凭 valid 就阻止本机发送。
                if (lowMacTxReqQ.notEmpty && !(rxValidReg && (rxPowerReg > csThreash))) begin
                    let lowMactxReq = lowMacTxReqQ.first;
                    PhyEvent phyTxpkt = PhyEvent{
                        srcPhyId: lowMactxReq.srcMacId,
                        dstPhyId: lowMactxReq.dstMacId,
                        rfParam: lowMactxReq.rfParam,
                        ppduLen: unpack(pack(lowMactxReq.mpduDigest.length)),
                        mpduDigest: lowMactxReq.mpduDigest
                    };
                    lowMacTxReqQ.deq;
                    lowMacTxRespQ.enq(GenericResp{});
                    phyTxReqQ.enq(phyTxpkt);
                    txTimingQ.enq(PhyTimingReq{
                        tag: PhyTimingTag{tx: True, strong: True, started: phyCycle},
                        length: unpack(phyTxpkt.ppduLen), mcs: phyTxpkt.rfParam.mcs});
                    currentTxEpoch <= phyCycle;
                    txBeginReg      <= True;
                    stateReg        <= PHY_TX;
                    txTimerReg      <= syncTime;
                    currentMcsReg   <= phyTxpkt.rfParam.mcs;
                    currentPowerReg <= phyTxpkt.rfParam.power;
                    currentLenReg   <= unpack(pack(phyTxpkt.ppduLen));
                    // $display("PHY_TX start");
                    $display("[%8d ns] id: %0d, PHY_TX start", $time, id);
                    // immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Phy Tx Start", id));
                end
                else if (rxValidReg && (rxPowerReg > csThreash) && phyCycle - rxArrivalReg < syncTime) begin
                    // 进入同步状态 (CS 门限: 弱于门限的帧不占用接收机, 对齐隐藏节点语义)
                    rxBeginReg      <= True;
                    stateReg        <= PHY_SYNC;
                    syncTimerReg    <= syncTime - (phyCycle - rxArrivalReg) - 1;
                    currentRxEpoch <= rxArrivalReg;
                    rxTimerReg <= 0;
                    syncLookupSent <= False;
                    dataLookupSent <= False;
                    syncPerReady <= False;
                    dataPerReady <= False;
                    currentSrcipReg <= rxSrcipReg;
                    currentDstipReg <= rxDstipReg;
                    currentMcsReg   <= rxMcsReg;
                    currentPowerReg <= rxPowerReg;
                    currentLenReg   <= rxLenReg;
                    currentMpduDigest <= rxMpduDigest;
                    // if(id==0 || id == 1)
                    // $display("%0d PHY_SYNC start, power:%d",id,rxPowerReg);
                    // $display("[%8d ns] PHY_SYNC start, power:%d",$time, rxPowerReg);
                    // immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Phy Sync Start,power: %0d", id, rxPowerReg));
                end
            end
    
            PHY_SYNC: begin
                // 碰撞: 同步中被新强帧重叠 -> 判废
                if (rxValidReg && (rxPowerReg > csThreash)) begin
                    collideReg <= True;
                    $display("[%8d ns] id: %0d, COLLISION in SYNC (power:%d)",
                             $time, id, rxPowerReg);
                end
                // 同步计时器处理
                if (syncTimerReg > 0) begin
                    syncTimerReg <= syncTimerReg - 1;
                end
    
                // T02: 查表请求只发一次，并携带阶段/帧标记。128周期覆盖搜索和BRAM延迟。
                if (!syncLookupSent && syncTimerReg <= 128) begin
                    lookupReqQ.enq(PhyLookupTag{payload: False, epoch: currentRxEpoch,
                        mcs: currentMcsReg, power: currentPowerReg});
                    syncLookupSent <= True;
                end
                if (perResults.notEmpty) begin
                    let {tag, value} = perResults.first;
                    perResults.deq;
                    if (tag.epoch == currentRxEpoch && !tag.payload) begin
                        syncPerValue <= value;
                        syncPerReady <= True;
                    end
                end
                if (syncTimerReg == 0 && syncPerReady) begin
                    syncEndReg <= True;
                    syncCrcReg <= syncPerValue >= unpack(randomValueReg);
                    stateReg <= PHY_RX;
                end
            end

            PHY_RX: begin
                if (rxValidReg && rxPowerReg > csThreash && rxTimerReg > 0)
                    collideReg <= True;
                if (!dataLookupSent && !rxBeginReg && rxTimerReg <= 128) begin
                    lookupReqQ.enq(PhyLookupTag{payload: True, epoch: currentRxEpoch,
                        mcs: currentMcsReg, power: currentPowerReg});
                    dataLookupSent <= True;
                end
                if (perResults.notEmpty) begin
                    let {tag, value} = perResults.first;
                    perResults.deq;
                    if (tag.epoch == currentRxEpoch && tag.payload) begin
                        dataPerValue <= value;
                        dataPerReady <= True;
                    end
                end
                if (!rxBeginReg && rxTimerReg == 0 && dataPerReady) begin
                    Bool correct = dataPerValue >= unpack(randomValueReg) && !collideReg && currentMcsReg < 8;
                    // C02: 成功数据直接进入原输出 FIFO；满时保留该完成决定，不丢 CRC 脉冲。
                    if (correct) lowMacRxReqQ.enq(MacEvent{
                        srcMacId: currentSrcipReg, dstMacId: currentDstipReg,
                        rfParam: RfParam{power: currentPowerReg, mcs: currentMcsReg},
                        mpduDigest: currentMpduDigest, status: True});
                    stateReg <= PHY_IDLE;
                    rxEndReg <= True;
                    crcReg <= correct;
                    collideReg <= False;
                end
            end

            PHY_TX: begin
                // $display("[%8d ns] PHY_TX", $time);
                // 发送计时器处理
                if (txBeginReg) begin
                    // 必须等本帧的带标签结果；不能在结果排队时按初值提前结束发送。
                    if (txTimeValid) begin
                        txTimerReg <= txRemaining > 0 ? txRemaining - 1 : 0;
                        txBeginReg <= False;
                    end
                    // if(id==0 || id == 1)
                        // $display("%d tx time: %0d (clk)", id, syncTime + psduTimeWire);
                    //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, tx time: %0d (clk)", id, syncTime + psduTimeWire));
                end 
                else if (txTimerReg > 0) begin
                    txTimerReg <= txTimerReg - 1;
                end 
                else begin
                    stateReg <= PHY_IDLE;
                    txEndReg <= True;
                    $display("[%8d ns] PHY_TX END", $time);
                    // if(id==0 || id == 1)
                    //     $display("%d PHY_TX END", id);
                    //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Phy Tx End", id));
                end
            end
    
            default: begin
                stateReg <= PHY_IDLE;  // 异常恢复
                //$display("Unknown state, reset to IDLE");
                //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Unknown state, reset to IDLE", id));
            end
        endcase
    endrule


    //---------------------------
    //RandI 16
    //---------------------------
    RandI#(16) randGen <- mkRn_16;


    rule getRand;
        let tmpRand    <- randGen.get();  
        randomValueReg <= tmpRand;
    endrule

    //---------------------------
    // ROM
    //---------------------------
    Rom1port#(UInt#(12),UInt#(32)) rom1 <- mkSingleRom("Lg.mem");
    BinarySearchIFC searcher <- mkBinarySearch;

    // Rom1port#(UInt#(14),UInt#(16)) rom2 <- mkSingleRom("Per.mem");
    //     //ram的外部定义，需要暴露另一端口给DMA配置  d:10
    BRAM2Port#(PerIn, PerOut) perRam <- mkBRAM2Server(
        // defaultValue
        BRAM_Configure {                            
            memorySize   : 16383,
            loadFormat   : tagged Hex "Per.mem",
            latency      : 2,
            outFIFODepth : 4,
            allowWriteResponseBypass : False
        }
    );

    //功率值查表映射（Q6.5定点数）
    rule putAddr1 if ((stateReg == PHY_SYNC || stateReg == PHY_RX) && rxValidReg);
        UInt#(12) addr1 = unpack(pack(rxPowerReg + 2047 + 1));
        rom1.request.put(addr1);
        // $display("addr1: %0d", addr1);
    endrule
    // T02: 搜索响应与请求标签同步消费；PHY 状态变化不会改变该次查表的 MCS/功率。
    rule search_result;
        let noise <- searcher.get;
        let tag = searchTags.first;
        searchTags.deq;
        Int#(13) snr = signExtend(tag.power) - signExtend(noise);
        UInt#(13) sinrIndex = unpack(pack(snr + 160));
        UInt#(14) index = snr < -160 ? 0 : (snr >= 960 ? 1119 : zeroExtend(sinrIndex));
        if (tag.payload) index = index + zeroExtend(unpack(tag.mcs)) * 1120;
        perRam.portB.request.put(BRAMRequest{write: False, responseOnWrite: False,
            address: index, datain: 0});
        perTags.enq(tag);
    endrule

    //---------------------------
    // let
    //---------------------------
    Reg#(Maybe#(File)) fdReg <- mkReg(Invalid);

    // 打开文件（仅在初始化时执行一次）
    // rule openFile if (!isValid(fdReg));
    //     let fd <- $fopen("/home/psz/RealEmu/scripts/PhyCore.txt", "a");
    //     fdReg <= tagged Valid fd;
    //     $display("File opened.");
    // endrule

    rule let1;
        let value <- perRam.portB.response.get;
        perResults.enq(tuple2(perTags.first, value));
        perTags.deq;
    endrule

    Reg#(UInt#(32)) currentmaxReg <- mkReg(0);
    Reg#(UInt#(32)) currentReg <- mkDReg(0);
    Reg#(UInt#(32)) noiseSumReg <- mkReg(noisePower);
    Reg#(UInt#(32)) cycleCount <- mkReg(0);
    UInt#(32) sinrSmaple = 5 * clkFreq;
    rule feed_test;
        searcher.put(noiseSumReg);
        searchTags.enq(lookupReqQ.first);
        lookupReqQ.deq;
    endrule

    //---------------------------
    // SINR
    //--------------------------
    rule rom1Get;
        let data <- rom1.response.get;
        currentReg <= data;
        //$display("max : %0d",data);
        // immLog("mkPhyYansWifi", "rom1Get", $format("Id %5d, max : %0d", id, data));
    endrule

    rule updateMaxpower((stateReg == PHY_SYNC) || (stateReg == PHY_RX)) ;
        if(rxEndReg || syncEndReg) 
            currentmaxReg <= 0;
        else if(cycleCount == sinrSmaple - 1)
            currentmaxReg <= 0;
        else if (currentReg > currentmaxReg) begin
            currentmaxReg <= currentReg;
            // $display("max : %0d\n",currentReg);
        end 
    endrule

    rule handleCycleEnd((stateReg == PHY_SYNC) || (stateReg == PHY_RX));
        if(rxEndReg || syncEndReg) begin
            noiseSumReg <=  noisePower;
        end 
        else if(cycleCount == sinrSmaple - 1) begin
            noiseSumReg <= noiseSumReg + currentmaxReg;
        end
    endrule

    rule incrementCounter((stateReg == PHY_SYNC) || (stateReg == PHY_RX));
        if(cycleCount == sinrSmaple - 1)
              cycleCount <= 0;
        else
              cycleCount <= cycleCount + 1;
    endrule

    // rule handlephyStatusReq;
    //     if (phyStatusReqQ.notEmpty) begin
    //         let req = phyStatusReqQ.first;
    //         phyStatusReqQ.deq;
    //         let resp = getEmptyPhyStatusResp();
    //         let newPhyStatus = PhyStatus {
    //             cca         : ccaBusyReg,
    //             fcsEn       : rxEndReg,
    //             fcsCorrect  : crcReg,
    //             txStart     : txBeginReg,
    //             txEnd       : txEndReg,
    //             rxStart     : rxBeginReg,
    //             rxEnd       : rxEndReg,
    //             state       : stateReg
    //         };
    //         resp.phyStatus = newPhyStatus;
    //         phyStatusRespQ.enq(resp);
    //     end
    // endrule

    // 寄存器访问处理规则
    rule handlePhyRegAccess;
        let req = phyRegReqQ.first;
        phyRegReqQ.deq;
        RegAccessResp resp = RegAccessResp{readData: 0, error: False};
        
        // 寄存器访问逻辑
        case (req.regOffset)
            // PHY 状态寄存器 (仅查询)
            phy_fsm_state_off: begin
                resp.readData = zeroExtend(pack(stateReg));
            end
            phy_cca_busy_off: begin
                resp.readData = zeroExtend(pack(ccaBusyReg));
            end
            rx_power_dbm_off: begin
                resp.readData = zeroExtend(pack(rxPowerReg));
            end
            fcs_en_h: begin
                resp.readData = zeroExtend(pack(rxEndReg));
            end
            fcs_correct_h: begin
                resp.readData = zeroExtend(pack(crcReg));
            end
            
            default: begin
                resp.error = True;
                $display("[PhyCore:%0d] Invalid register offset: 0x%03h", id, req.regOffset);
            end
        endcase
        
        phyRegRespQ.enq(resp);
    endrule


    //更新per配置
    rule updatePerCfg;
        let perCfg = perTxReqQ.first;
        perTxReqQ.deq;
        let bramReq = BRAMRequest {
                write: True,
                responseOnWrite: True,
                address: perCfg.perIn,
                datain: perCfg.perOut
            };
        perRam.portA.request.put(bramReq);
    endrule
    // C02: 该响应表示写入已完成，不只是 perTxReqQ 已被取走。
    rule confirmPerCfg;
        let ignored <- perRam.portA.response.get;
        perTxRespQ.enq(GenericResp{});
    endrule
    //---------------------------
    // interface method
    //---------------------------
    interface lowMacTxSrv = toGPServer(lowMacTxReqQ, lowMacTxRespQ);
    interface lowMacRxClt = toGPClient(lowMacRxReqQ, lowMacRxRespQ);
    interface phyRegSrv   = toGPServer(phyRegReqQ, phyRegRespQ);
    interface perSrv      = toGPServer(perTxReqQ, perTxRespQ);

    interface phyTxClt    = toGPClient(phyTxReqQ, phyTxRespQ);
    interface Server phyRxSrv;
        interface Put request;
            method Action put(PhyEvent evt);
                phyRxReqQ.enq(tuple2(phyCycle, evt));
            endmethod
        endinterface
        interface response = toGet(phyRxRespQ);
    endinterface

    // interface phyStatusSrv = toGPServer(phyStatusReqQ, phyStatusRespQ);

    interface Get getPhyStatus;
        method ActionValue#(PhyStatus) get;
            return PhyStatus {
                cca         : ccaBusyReg,
                fcsEn       : rxEndReg,
                fcsCorrect  : crcReg,
                txStart     : txBeginReg,
                txEnd       : txEndReg,
                rxStart     : rxBeginReg,
                rxEnd       : rxEndReg,
                state       : stateReg
            };
        endmethod
    endinterface
endmodule


// ================================== BinarySearchIFC ==============================
typedef 4096 ROM_SIZE;
    
interface BinarySearchIFC;
    method Action put(UInt#(32) target);
    method ActionValue#(Int#(12)) get;  // 修改返回类型
endinterface

module mkBinarySearch(BinarySearchIFC);
    // ROM接口
    Rom1port#(UInt#(12), UInt#(32)) rom3 <- mkSingleRom("Lg.mem");
    
    // 状态寄存器
    Reg#(UInt#(12))  lowReg         <- mkReg(0);
    Reg#(UInt#(12))  highReg        <- mkReg(4095);
    Reg#(UInt#(32))  targetReg      <- mkReg(0);
    Reg#(UInt#(12))  midReg         <- mkReg(0);  
    Reg#(Bool)       searchingReg   <- mkReg(False);
    Reg#(Bool)       searchWaitReg  <- mkReg(False);
    Reg#(UInt#(6))   stepReg        <- mkReg(0);
    
    FIFO#(UInt#(32)) inputQ         <- mkFIFO;
    FIFO#(UInt#(12)) outputQ        <- mkFIFO;

    // 主状态机规则
    rule startSearch (!searchingReg);
        let target = inputQ.first;
        inputQ.deq;
        targetReg    <= target;
        lowReg       <= 0;
        highReg      <= 4095;
        stepReg      <= 0;        
        searchingReg <= True;
    endrule

    rule search (searchingReg && !searchWaitReg);
        UInt#(12) mid   = (lowReg >> 1) + (highReg >> 1);
        if (stepReg < 12) begin
            rom3.request.put(mid);
            searchWaitReg  <= True;
            stepReg  <=  stepReg + 1;
            midReg   <=  mid;
        end 
        else begin
            stepReg <= 0;
            outputQ.enq(mid);
            searchingReg   <= False;
        end
    endrule

    rule handleResponse (searchingReg && searchWaitReg);
        let data <- rom3.response.get;
        searchWaitReg  <= False;
        if (data < targetReg) begin
            lowReg  <= midReg + 1;
        end 
        else if(data > targetReg)begin
            highReg  <= midReg - 1;
        end else begin
            // $display("equal");
        end 
    endrule

    method Action put(UInt#(32) target);
        inputQ.enq(target);
    endmethod

    method ActionValue#((Int#(12))) get;
        let data = outputQ.first;
        outputQ.deq;
        Int#(12) res = unpack(pack(data - 2048));
        return res;
    endmethod

endmodule



// ================================== LFSR ==============================
//export mkRn_16;
// We want 16-bit random numbers, so we will use the 16-bit version of
// LFSR and take the most significant eight bits.
// The interface for the random number generator is parameterized on bit
// length. It is a "get" interface, defined in the GetPut package.

// interface LFSR #(type a_type);
//     method Action seed(a_type seed_value);
//     method a_type value();
//     method Action next();
// endinterface: LFSR
    
typedef Get#(Bit#(n)) RandI#(type n);
module mkRn_16(RandI#(16));
    // First we instantiate the LFSR module
    LFSR#(Bit#(16)) lfsr <- mkLFSR_16 ;
    // Next comes a FIFO for storing the results until needed
    FIFO#(Bit#(16)) fi <- mkFIFO ;
    // A boolean flag for ensuring that we first seed the LFSR module
    Reg#(Bool) starting <- mkReg(True) ;
    // This rule fires first, and sends a suitable seed to the module.
    rule start (starting);
        starting <= False;
        lfsr.seed('h11);
    endrule: start
    // After that, the following rule runs as often as it can, retrieving
    // results from the LFSR module and enqueing them on the FIFO.
    rule run (!starting);
        fi.enq(lfsr.value[15:0]);
        lfsr.next;
    endrule: run
    // The interface for mkRn_6 is a Get interface. We can produce this from a
    // FIFO using the fifoToGet function. We therefore don’t need to define any
    // new methods explicitly in this module: we can simply return the produced
    // Get interface as the "result" of this module instantiation.
    return fifoToGet(fi);
endmodule
