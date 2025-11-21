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

/*  
 *  MacEvent --->(PPDU DATA)-----> | MacCore | ---->(RTS,CTS,DATA,ACK)----> |PhyCore| ----> |Channel|
 */

interface MacCore;
    interface MacSrv highMacTxSrv;
    interface MacClt highMacRxClt;

    interface MacSrv lowMacRxSrv;
    interface MacClt lowMacTxClt;

    interface Put#(MacConfig) configure;
    interface Put#(PhyStatus) phyStatus;
endinterface

// A Fake MAC without any access control
(* always_enabled = "phyStatus.put" *)
module mkMacPipe#(Integer id)(MacCore);
    FIFO#(MacEvent)    highMacTxReqQ  <- mkFIFO;
    FIFO#(GenericResp) highMacTxRespQ <- mkFIFO;
    FIFO#(MacEvent)    highMacRxReqQ  <- mkFIFO;
    FIFO#(GenericResp) highMacRxRespQ <- mkFIFO;

    FIFO#(MacEvent)    lowMacTxReqQ   <- mkFIFO;
    FIFO#(GenericResp) lowMacTxRespQ  <- mkFIFO;
    FIFO#(MacEvent)    lowMacRxReqQ   <- mkFIFO;
    FIFO#(GenericResp) lowMacRxRespQ  <- mkFIFO;

    Reg#(MacConfig)  macCfgReg      <- mkReg(getDefaultMacCfg);
    Reg#(MacStatus)  macStaReg      <- mkReg(MacStatus{backOffState:CSMA_IDLE, dcfState:DCF_IDLE});

    Wire#(PhyStatus)  phyStatusWire <- mkBypassWire;

    rule forwardTx;
        let txReq = highMacTxReqQ.first;
        highMacTxReqQ.deq;
        highMacTxRespQ.enq(GenericResp{});
        lowMacTxReqQ.enq(txReq);
    endrule

    rule handshakeTx;
        lowMacTxRespQ.deq;
    endrule

    rule forwardRx;
        let rxReq = lowMacRxReqQ.first;
        lowMacRxReqQ.deq;
        if (rxReq.dstMacId == fromInteger(id)) begin
            highMacRxReqQ.enq(rxReq);
        end
    endrule

    rule handshakeRx;
        highMacRxRespQ.deq;
    endrule

    interface highMacTxSrv = toGPServer(highMacTxReqQ, highMacTxRespQ);
    interface highMacRxClt = toGPClient(highMacRxReqQ, highMacRxRespQ);
    interface lowMacTxClt  = toGPClient(lowMacTxReqQ, lowMacTxRespQ);
    interface lowMacRxSrv  = toGPServer(lowMacRxReqQ, lowMacRxRespQ);
    
    interface Put phyStatus;
        method Action put(PhyStatus phyStatus);
            phyStatusWire <= phyStatus;
        endmethod
    endinterface

    interface Put configure;
        method Action put(MacConfig cfg);
            macCfgReg <= cfg;
        endmethod
    endinterface
    
    //interface configSrv    = toGPServer(configReqQ, configRespQ);
endmodule

// ============================= 802.11 NAV ==============================
interface Nav_IFC;
    method Action               handleFrame(MacEvent frame);        // 统一处理帧
    method Action               resetNav();                         // 强制复位NAV
    method Duration             getNavValue();                      // 获取当前NAV值
    method Bool                 isNavWaiting();                     // NAV是否等待完成
    interface Put#(MacConfig)   configure;                          // 配置参数
endinterface

module mkNav#(
    TimeGen usGen,
    Integer id            
)(Nav_IFC);
    // --------------------- 寄存器声明 ---------------------
    Reg#(Duration)           navReg                  <- mkReg(0);
    Reg#(Duration)           newNavReg               <- mkDReg(0);
    Reg#(MacConfig)          macCfg                  <- mkReg(getDefaultMacCfg);
    
    // --------------------- 内部逻辑 ---------------------
    // RTS超时检测以及等待nav
    rule checkRtsTimeout;
        if (usGen.get && navReg > newNavReg && navReg > 0) begin
            navReg <= navReg - 1;
            // immLog("mkNav", "checkRtsTimeout" , $format("Node %0d: NAV decrease navReg = %0d", id , navReg));
        end
        else if (navReg < newNavReg)
            navReg <= newNavReg;
        else
            navReg <= navReg;
    endrule

    method Action handleFrame(MacEvent frame);
        Duration timeoutThresholdReg = zeroExtend(2 * macCfg.sifs + 2 * macCfg.slot + macCfg.sigTime + macCfg.ofdmSymbolTime * macCfg.maxNum + macCfg.phyDelayTime); //参考openwifi
        // 处理Duration字段
        if (frame.mpduDigest.duration[15] == 0) begin
            // $display("duration = %0d",frame.mpduDigest.duration[14:0]);
            if(zeroExtend(frame.mpduDigest.duration[14:0]) > timeoutThresholdReg) begin
                newNavReg <= timeoutThresholdReg;
            end
            else begin
                newNavReg <= zeroExtend(frame.mpduDigest.duration[14:0]);
            end
        end
    endmethod

    method Action resetNav();
        // immLog("mkNav", "resetNav" , $format("Node %0d: Manual NAV reset", id));
    endmethod

    method Duration getNavValue() = navReg;
    
    method Bool isNavWaiting() = (navReg != 0);

    interface Put configure;
        method Action put(MacConfig cfg);
            macCfg <= cfg;
        endmethod
    endinterface
endmodule

// ================================== 802.11 DCF MAC ================================
interface CsmaBackOff_IFC;
    method Action    start(Tuple2#(Bool,Bool) option);  // tuple2(isDifs, isNeedStage2RandomBackOff)
    method Action    softRst();             // 软复位，上层强制清空CSMA状态机
    method Action    incrCW();              // 碰撞后指数增长窗口
    method Action    resetCW();             // 成功接收窗口
    method Bool      available();           // 退避模块是否可用，仅当可用时调用start
    method CsmaState getStatus();           // 获取退避状态机当前状态
    method Bool      done();                // 退避完成
    interface Put#(MacConfig) configure;    // 配置退避状态机参数
    interface Nav_IFC navctrl;
endinterface

module mkCsmaCaBackOff#(
    Wire#(PhyStatus) phyStatusWire,
    TimeGen usGen,
    TimeGen slotGen,
    Integer id
)(CsmaBackOff_IFC);
    Reg#(CsmaState)  csmaStateReg           <- mkReg(CSMA_IDLE);
    Reg#(Bool)       isSendAllowReg         <- mkDReg(False);

    Reg#(TimeUs)     waitTimeIFSReg         <- mkReg(0);
    Reg#(TimeSlot)   waitTimeReg            <- mkReg(0);

    Reg#(Bool)       startReg               <- mkDReg(False);
    PulseWire        resetWire              <- mkPulseWire;

    Reg#(MacConfig)  macCfgReg              <- mkReg(getDefaultMacCfg);
    Reg#(Bool)       isSifsReg              <- mkReg(False);  // Option1: 是否是短帧间间隔类型退避
    Reg#(Bool)       isExpBackOffReg        <- mkReg(False);  // Option2: IFS退避后是否需要随机退避

    let              expBackOffGen          <- mkExpBackoffGenerator;
    let              navController          <- mkNav(usGen, id);  //检查逻辑发现可能是一个冗余项，暂时保留
    
    Reg#(TimeUs) suspendTimer <- mkReg(0);
    rule csmaFSM;

        case (csmaStateReg)

            // 初始状态，仅当IDLE时可以使用start方法
            CSMA_IDLE: begin
                isSendAllowReg <= False;
                if (startReg) begin
                    waitTimeIFSReg <= isSifsReg ? macCfgReg.sifs : macCfgReg.difs;   // unit is us
                    if (phyStatusWire.cca || navController.isNavWaiting()) begin
                        csmaStateReg <= CSMA_BUSY;
                    end 
                    else begin
                        csmaStateReg <= CSMA_BACKOFF_IFS;
                    end
                end
                // else do nothing
            end

            // 信道繁忙：需要重启IFS倒计时
            CSMA_BUSY: begin
                if (resetWire) begin
                    csmaStateReg <= CSMA_IDLE;
                end
                else if(!(phyStatusWire.cca || navController.isNavWaiting())) begin
                    if((!phyStatusWire.fcsCorrect) && phyStatusWire.fcsEn) begin
                        waitTimeIFSReg <= macCfgReg.eifs;
                    end
                    else begin
                        waitTimeIFSReg <= isSifsReg ? macCfgReg.sifs : macCfgReg.difs;
                    end
                    csmaStateReg <= CSMA_BACKOFF_IFS;
                end
                // else do nothing
            end

            // 倒计时 SIFS/DIFS/EIFS
            CSMA_BACKOFF_IFS: begin
                if (resetWire) begin
                    csmaStateReg <= CSMA_IDLE;
                end
                else if(phyStatusWire.cca || navController.isNavWaiting()) begin
                    csmaStateReg <= CSMA_BUSY;
                end
                else begin
                    if (waitTimeIFSReg == 0) begin
                        // 需要进行指数增长随机退避
                        if (isExpBackOffReg) begin
                            csmaStateReg <= CSMA_BACKOFF;
                            let randWaitTime <- expBackOffGen.next.get;
                            waitTimeReg <= randWaitTime;
                            // immLog("mkCsmaCaBackOff", "csmaFSM", $format("Id %5d, Enter ExpWindow BackOff, randWaitTime = ", id, randWaitTime));
                        end
                        // 只进行IFS退避，无需进行随机退避
                        else begin
                            csmaStateReg <= CSMA_DONE;
                            // immLog("mkCsmaCaBackOff", "csmaFSM", $format("Id %5d, BackOff Done without expWindow", id));
                        end
                    end
                    else if (usGen.get) begin
                        waitTimeIFSReg <= waitTimeIFSReg - 1;
                    end
                    // else do nothing
                end
            end

            // 指数增长随机退避
            CSMA_BACKOFF: begin
                if (resetWire) begin
                    csmaStateReg <= CSMA_IDLE;
                end
                else if(phyStatusWire.cca || navController.isNavWaiting()) begin
                    csmaStateReg <= CSMA_SUSPEND;
                end
                else begin
                    if(waitTimeReg == 0) begin
                        csmaStateReg <= CSMA_DONE;
                        // immLog("mkCsmaCaBackOff", "csmaFSM", $format("Id %5d, BackOff Done", id));
                    end
                    else if (slotGen.get) begin
                        waitTimeReg <= waitTimeReg - 1;
                    end
                    // else : Do Nothing
                end
            end

            // 指数随机退避期间暂停，保留退避窗口
            CSMA_SUSPEND: begin
                if (resetWire) begin
                    csmaStateReg <= CSMA_IDLE;
                end
                else if(!(phyStatusWire.cca || navController.isNavWaiting())) begin
                    csmaStateReg <= CSMA_BACKOFF;
                end
                // else do nothing
            end

            CSMA_DONE: begin
                isSendAllowReg   <= True;
                csmaStateReg     <= CSMA_IDLE;
                waitTimeReg      <= 0;  // 重置退避计数器
            end
        endcase
    endrule

    // 启动一次退避
    method Action start(Tuple2#(Bool,Bool) option);
        startReg  <= True;
        let {isSifs, isExpBackOff} = option;
        isSifsReg <= isSifs;
        isExpBackOffReg <= isExpBackOff;
    endmethod

    // 退避状态机是否可用
    method Bool available();
        return (csmaStateReg == CSMA_IDLE);
    endmethod

    // 查询退避状态机状态
    method  CsmaState getStatus();
        return csmaStateReg;
    endmethod

    // 退避是否完成
    method Bool done();
        return isSendAllowReg;
    endmethod

    // 强制状态机重置
    method Action softRst();
        resetWire.send;
    endmethod

    // 传输失败增窗
    method Action incrCW();
        expBackOffGen.incrCW;
    endmethod

    // 传输成功重置窗口
    method Action resetCW();
        expBackOffGen.resetCW;
    endmethod

    // 配置参数
    interface Put configure;
        method Action put(MacConfig macCfg);
            macCfgReg <= macCfg;
            expBackOffGen.configure.put(macCfg);
        endmethod
    endinterface

    //引出nav模块配置
    interface navctrl = navController;

endmodule

// 802.11 DCF Low Mac Layer

(* always_enabled = "phyStatus.put" *)
// (* synthesize *)
module mkMacDCF#(Integer id)(MacCore);
    FIFOF#(MacEvent)    highMacTxReqQ  <- mkFIFOF;
    FIFOF#(GenericResp) highMacTxRespQ <- mkFIFOF;
    FIFOF#(MacEvent)    highMacRxReqQ  <- mkFIFOF;
    FIFOF#(GenericResp) highMacRxRespQ <- mkFIFOF;

    FIFOF#(MacEvent)    lowMacTxReqQ   <- mkFIFOF;
    FIFOF#(GenericResp) lowMacTxRespQ  <- mkFIFOF;
    FIFOF#(MacEvent)    lowMacRxReqQ   <- mkFIFOF;
    FIFOF#(GenericResp) lowMacRxRespQ  <- mkFIFOF;

    Reg#(MacConfig)  macCfgReg      <- mkReg(getDefaultMacCfg);
    Reg#(MacStatus)  macStaReg      <- mkReg(MacStatus{backOffState:CSMA_IDLE, dcfState:DCF_IDLE});

    Reg#(MacEvent)   lasthighMacTxReq             <- mkReg(getDefaultMacEvent);

    Wire#(PhyStatus)  phyStatusWire       <- mkBypassWire;
    
    Reg#(DcfNextTask)    nextTaskReg        <- mkReg(NT_IDLE);
    Reg#(DcfState)       dcfStateReg        <- mkReg(DCF_IDLE);
    Reg#(RetryTime)      retransCountReg    <- mkReg(0);
    Reg#(TimeUs)         ackTimeoutCountReg <- mkReg(0);

`ifdef BSIM
    TimeGen              usGen              <- mkUsGen(1);
`else
    TimeGen              usGen              <- mkUsGen(200);
`endif
    TimeGen              slotGen            <- mkSlotGen(usGen, macCfgReg);
    let                  backOffFsm         <- mkCsmaCaBackOff(phyStatusWire, usGen, slotGen, id);

    rule phyHandShake;
        lowMacTxRespQ.deq;
    endrule

    rule highMacHandShake;
        highMacRxRespQ.deq;
    endrule

    rule dcfFsmIdle if (dcfStateReg == DCF_IDLE);
            let nextTask = nextTaskReg;
            let state = DCF_IDLE;
            ackTimeoutCountReg <= 0;
            // Phy->lowMac接收队列非空, 进入接收处理逻辑
            if (lowMacRxReqQ.notEmpty) begin
                // $display("lowMacRxReqQ.notEmpty");
                let rxReq = lowMacRxReqQ.first;
                if (isMyFrame(id, rxReq.dstMacId) && isDataFrame(rxReq.mpduDigest)) begin
                    // 收到Data帧，需要回复ACK，先退避SIFS
                    nextTask = NT_SEND_ACK;
                    state = DCF_WAIT_BACKOFF;
                    backOffFsm.start(tuple2(True, False)); //SIFS 
                    rxReq.status = True;
                    highMacRxReqQ.enq(rxReq);
                    $display("recv pkt in mac layer, my mac id is %d, dst mac id is %d", id,rxReq.dstMacId);
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Receive DATA", id));
                end
                else if (isMyFrame(id, rxReq.dstMacId) && isRtsFrame(rxReq.mpduDigest)) begin
                    // 收到RTS帧，需要回复CTS，先退避SIFS
                    nextTask = NT_SEND_CTS;
                    state = DCF_WAIT_BACKOFF;
                    backOffFsm.start(tuple2(True, False)); //SIFS 
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Receive RTS", id));
                end
                else if (!isMyFrame(id, rxReq.dstMacId) && isRtsFrame(rxReq.mpduDigest)) begin
                    backOffFsm.navctrl.handleFrame(rxReq);       //新增nav逻辑
                    lowMacRxReqQ.deq;
                    lowMacRxRespQ.enq(GenericResp{});
                end
                else begin
                    // 直接丢弃
                    lowMacRxReqQ.deq;
                    // $display("throw pkt in mac layer, my mac id is %d, dst mac id is %d", id,rxReq.dstMacId);
                    lowMacRxRespQ.enq(GenericResp{});
                    // else do nothing.
                end
            end
            // highMac->lowMac发送队列非空，进入发送处理逻辑，可能需要发送Data或者RTS
            else if (highMacTxReqQ.notEmpty) begin
                // if (backOffFsm.available) begin
                    if (nextTaskReg == NT_IDLE) begin
                    // 一次新的发送/重传
                        backOffFsm.start(tuple2(False, True)); //DIFS and expBackOff
                        let txReq = highMacTxReqQ.first;
                        // 长帧使用RTS
                        if (txReq.mpduDigest.length > macCfgReg.rtsThreshold) begin
                            nextTask = NT_SEND_RTS;
                        end
                        else begin
                            nextTask = NT_SEND_DATA;
                        end
                    end
                    else if (nextTaskReg == NT_SEND_DATA) begin
                    // 发送了RTS，并且已经收到了CTS
                        backOffFsm.start(tuple2(True, False)); //SIFS 
                        nextTask = NT_SEND_DATA;
                        // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, CTS SIFS", id));
                    end
                    // else do nothing 
                    state = DCF_WAIT_BACKOFF;
                // end
                // else do nothing
            end
            // else do nothing     
            nextTaskReg <= nextTask;
            dcfStateReg  <= state;
        endrule

        // Reg#(UInt#(64)) cycleCount <- mkReg(0);
        // rule updateclock;
        //     cycleCount <= cycleCount + 1;
        // endrule

        // 更新下发参考值
        rule updateCtlFramPower;
            if(highMacTxReqQ.notEmpty) begin
            lasthighMacTxReq <= highMacTxReqQ.first;
            // immLog("mkMacDcf", "updatepower", $format("Id %5d, update power:%d", id, lasthighMacTxReq.rfParam.power));
            end
        endrule

        // 等待退避机制结束
        rule dcfWaitBackOff if (dcfStateReg == DCF_WAIT_BACKOFF);
            if (backOffFsm.done) begin
                case (nextTaskReg)
                NT_SEND_RTS: begin
                    // 第一次BackOff，发送RTS帧
                    let refFrame = highMacTxReqQ.first;
                    let rtsFrame = setRtsFrame(refFrame);
                    lowMacTxReqQ.enq(rtsFrame);
                    dcfStateReg <= DCF_RECV_CTSACK;
                    nextTaskReg <= NT_RECV_CTS;
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Send RTS", id));
                    end
                NT_SEND_DATA: begin
                    // 已经收到过CTS，或者无需RTS/CRS, 发送Data
                    let refFrame = highMacTxReqQ.first;
                    lowMacTxReqQ.enq(refFrame);
                    dcfStateReg <= DCF_RECV_CTSACK;
                    nextTaskReg <= NT_RECV_ACK;
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Send Data", id));
                end
                NT_SEND_CTS: begin
                    // 回复CTS
                    let refFrame = lowMacRxReqQ.first;
                    refFrame.rfParam.power = lasthighMacTxReq.rfParam.power;    
                    lowMacRxReqQ.deq;
                    lowMacRxRespQ.enq(GenericResp{});
                    let ctsFrame = setCtsFrame(id, refFrame);
                    lowMacTxReqQ.enq(ctsFrame);
                    dcfStateReg <= DCF_IDLE;
                    nextTaskReg <= NT_RECV_DATA;
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Send CTS", id));
                end
                NT_SEND_ACK: begin
                    // 回复ACK
                    if(lowMacRxReqQ.notEmpty) begin
                        let refFrame = lowMacRxReqQ.first;
                        refFrame.rfParam.power = lasthighMacTxReq.rfParam.power;
                        lowMacRxReqQ.deq;
                        lowMacRxRespQ.enq(GenericResp{});
                        let ackFrame = setAckFrame(id, refFrame);
                        lowMacTxReqQ.enq(ackFrame);
                        dcfStateReg <= DCF_IDLE;
                        nextTaskReg <= NT_IDLE;
                    end
                // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Send ACK", id));
                end
                endcase
            end
        endrule

        // 等待对端反馈
        rule dcfRecvCtsAck if (dcfStateReg == DCF_RECV_CTSACK);
            let rxReq = lowMacRxReqQ.first;
            let nextTask = nextTaskReg;
            let state = dcfStateReg;
            if (usGen.get)
                ackTimeoutCountReg <= ackTimeoutCountReg + 1;
            if (lowMacRxReqQ.notEmpty) begin
                if (isMyFrame(id, rxReq.dstMacId) && isCtsFrame(rxReq.mpduDigest)) begin
                    // 收到了CTS，准备发送DATA
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Receive CTS", id));
                    lowMacRxReqQ.deq;
                    lowMacRxRespQ.enq(GenericResp{});
                    state = DCF_IDLE;
                    nextTask = NT_SEND_DATA;
                end
                else if (isMyFrame(id, rxReq.dstMacId) && isAckFrame(rxReq.mpduDigest)) begin
                    // 收到了ACK，结束一次发送
                    // TODO: Block ACK 如何处理？？
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Receive ACK", id));
                    lowMacRxReqQ.deq;
                    lowMacRxRespQ.enq(GenericResp{});
                    backOffFsm.resetCW;  // 重置窗口
                    nextTask = NT_IDLE;
                    state = DCF_IDLE;
                    highMacTxReqQ.deq;
                    highMacTxRespQ.enq(GenericResp{});
                    retransCountReg <= 0;
                end
                else begin
                    // 非预期的包，直接丢弃
                    lowMacRxReqQ.deq;
                end
            end
            // CTS/ACK超时，重新进入发送流程
            else if (ackTimeoutCountReg >= macCfgReg.timeout) begin
                if (retransCountReg < macCfgReg.retryLimit) begin
                    retransCountReg <= retransCountReg + 1;
                    backOffFsm.incrCW;  // 失败后增大退避窗口
                    immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Timeout, Retransmit", id));
                    state = DCF_IDLE;
                    nextTask = NT_IDLE;
                end 
                // 超过重试次数，发送失败
                else begin
                    retransCountReg <= 0;
                    backOffFsm.resetCW;  // 重置窗口
                    state = DCF_IDLE;
                    nextTask = NT_IDLE;
                    highMacTxReqQ.deq;
                    let txReq = highMacTxReqQ.first;
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Retransmit Time %d, Drop", id, retransCountReg));
                    txReq.status = False;
                    // highMacRxReqQ.enq(txReq);
                end
            end
            dcfStateReg <= state;
            nextTaskReg <= nextTask;
        endrule



    interface highMacTxSrv = toGPServer(highMacTxReqQ, highMacTxRespQ);
    interface highMacRxClt = toGPClient(highMacRxReqQ, highMacRxRespQ);
    interface lowMacTxClt  = toGPClient(lowMacTxReqQ, lowMacTxRespQ);
    interface lowMacRxSrv  = toGPServer(lowMacRxReqQ, lowMacRxRespQ);

    interface Put phyStatus;
        method Action put(PhyStatus phyStatus);
            phyStatusWire <= phyStatus;
        endmethod
    endinterface

    interface Put configure;
        method Action put(MacConfig cfg);
            macCfgReg <= cfg;
        endmethod
    endinterface
endmodule