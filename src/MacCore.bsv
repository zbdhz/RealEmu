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

    interface RegAccessSrv macRegSrv;

    interface Put#(PhyStatus) phyStatus;
endinterface

// A Fake MAC without any access control
// (* always_enabled = "phyStatus.put" *)
// module mkMacPipe#(Integer id)(MacCore);
//     FIFO#(MacEvent)    highMacTxReqQ  <- mkFIFO;
//     FIFO#(GenericResp) highMacTxRespQ <- mkFIFO;
//     FIFO#(MacEvent)    highMacRxReqQ  <- mkFIFO;
//     FIFO#(GenericResp) highMacRxRespQ <- mkFIFO;

//     FIFO#(MacEvent)    lowMacTxReqQ   <- mkFIFO;
//     FIFO#(GenericResp) lowMacTxRespQ  <- mkFIFO;
//     FIFO#(MacEvent)    lowMacRxReqQ   <- mkFIFO;
//     FIFO#(GenericResp) lowMacRxRespQ  <- mkFIFO;

//     Reg#(MacConfig)  macCfgReg      <- mkReg(getDefaultMacCfg);
//     Reg#(MacStatus)  macStaReg      <- mkReg(MacStatus{backOffState:CSMA_IDLE, dcfState:DCF_IDLE});

//     Wire#(PhyStatus)  phyStatusWire <- mkBypassWire;

//     rule forwardTx;
//         let txReq = highMacTxReqQ.first;
//         highMacTxReqQ.deq;
//         highMacTxRespQ.enq(GenericResp{});
//         lowMacTxReqQ.enq(txReq);
//     endrule

//     rule handshakeTx;
//         lowMacTxRespQ.deq;
//     endrule

//     rule forwardRx;
//         let rxReq = lowMacRxReqQ.first;
//         lowMacRxReqQ.deq;
//         if (rxReq.dstMacId == fromInteger(id)) begin
//             highMacRxReqQ.enq(rxReq);
//         end
//     endrule

//     rule handshakeRx;
//         highMacRxRespQ.deq;
//     endrule

//     interface highMacTxSrv = toGPServer(highMacTxReqQ, highMacTxRespQ);
//     interface highMacRxClt = toGPClient(highMacRxReqQ, highMacRxRespQ);
//     interface lowMacTxClt  = toGPClient(lowMacTxReqQ, lowMacTxRespQ);
//     interface lowMacRxSrv  = toGPServer(lowMacRxReqQ, lowMacRxRespQ);
    
//     interface Put phyStatus;
//         method Action put(PhyStatus phyStatus);
//             phyStatusWire <= phyStatus;
//         endmethod
//     endinterface

//     // interface Put putmaccfg;
//     //     method Action put(MacConfig cfg);
//     //         macCfgReg <= cfg;
//     //     endmethod
//     // endinterface

//     // interface Get getmaccfg;
//     //     method ActionValue#(MacConfig) get;
//     //         let cfg = macCfgReg;
//     //         return cfg;
//     //     endmethod
//     // endinterface
    
//     //interface configSrv    = toGPServer(configReqQ, configRespQ);
// endmodule

// ============================= 802.11 NAV ==============================
interface Nav_IFC;
    method Action               handleFrame(MacEvent frame);        // 统一处理帧
    method Action               resetNav();                         // 强制复位NAV
    method Duration             getNavValue();                      // 获取当前NAV值
    method Bool                 isNavWaiting();                     // NAV是否等待完成
    interface Put#(MacConfig)   putmaccfg;                          // 配置参数
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
            // $display("my id:%0d, duration = %0d",id,frame.mpduDigest.duration[14:0]);
            if(zeroExtend(frame.mpduDigest.duration[14:0]) < timeoutThresholdReg) begin
                newNavReg <= timeoutThresholdReg;
                // $display("myid:%d, newNavReg = %0d",id,timeoutThresholdReg);
                $display("my id:%0d, duration = %0d",id,timeoutThresholdReg);
                // newNavReg <= zeroExtend(frame.mpduDigest.duration[14:0]);
            end
            else begin
                $display("my id:%0d, duration = %0d",id,frame.mpduDigest.duration[14:0]);
                newNavReg <= zeroExtend(frame.mpduDigest.duration[14:0]);
            end
        end
        // if (frame.mpduDigest.duration[15] == 0) begin
        //     $display("my id:%0d, duration = %0d",id,frame.mpduDigest.duration[14:0]);
        //     newNavReg <= zeroExtend(frame.mpduDigest.duration[14:0]);
        // end
    endmethod

    method Action resetNav();
        // immLog("mkNav", "resetNav" , $format("Node %0d: Manual NAV reset", id));
    endmethod

    method Duration getNavValue() = navReg;
    
    method Bool isNavWaiting() = (navReg != 0);

    interface Put putmaccfg;
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
    interface Put#(MacConfig) putmaccfg;    // 配置退避状态机参数
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

    let              expBackOffGen          <- mkExpBackoffGenerator(id);
    let              navController          <- mkNav(usGen, id); 
    
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
                            immLog("mkCsmaCaBackOff", "csmaFSM", $format("Id %5d, Enter ExpWindow BackOff, randWaitTime = ", id, randWaitTime));
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
    interface Put putmaccfg;
        method Action put(MacConfig macCfg);
            macCfgReg <= macCfg;
            expBackOffGen.putmaccfg.put(macCfg);
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
    FIFOF#(MacEvent)    innerhighMacTxReqQ  <- mkSizedFIFOF(valueOf(MAC_FIFOIN_DEPTH));
    FIFOF#(GenericResp) highMacTxRespQ <- mkFIFOF;
    FIFOF#(MacEvent)    highMacRxReqQ  <- mkFIFOF;
    FIFOF#(GenericResp) highMacRxRespQ <- mkFIFOF;

    FIFOF#(MacEvent)    lowMacTxReqQ   <- mkFIFOF;
    FIFOF#(GenericResp) lowMacTxRespQ  <- mkFIFOF;
    FIFOF#(MacEvent)    lowMacRxReqQ   <- mkFIFOF;
    FIFOF#(GenericResp) lowMacRxRespQ  <- mkFIFOF;

    //新增配置查询和下发接口
    FIFOF#(RegAccessReq)  macRegReqQ  <- mkFIFOF;
    FIFOF#(RegAccessResp) macRegRespQ <- mkFIFOF;
    //新增包队列控制
    Reg#(UInt#(32))     mac_fifoin_count <- mkReg(0);
    Wire#(Int#(8))      countDeltaWire <- mkDReg(0);

    FIFOF#(MacEvent)    lowMacRxYesToMEReqQ  <- mkLFIFOF;
    FIFOF#(MacEvent)    lowMacRxNotToMEReqQ  <- mkLFIFOF;

    Reg#(MacConfig)  macCfgReg      <- mkReg(getDefaultMacCfg);
    Reg#(MacStatus)  macStaReg      <- mkReg(MacStatus{backOffState:CSMA_IDLE, dcfState:DCF_IDLE});

    Reg#(MacEvent)   lasthighMacTxReq             <- mkReg(getDefaultMacEvent);

    Wire#(PhyStatus)  phyStatusWire       <- mkBypassWire;
    
    Reg#(DcfNextTask)    nextTaskReg        <- mkReg(NT_IDLE);
    Reg#(DcfState)       dcfStateReg        <- mkReg(DCF_IDLE);
    Reg#(RetryTime)      retransCountReg    <- mkReg(0);
    Reg#(TimeUs)         ackTimeoutCountReg <- mkReg(0);
    Reg#(TimeUs)         ctsTimeoutCountReg <- mkReg(0);

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

    (* descending_urgency = "dcfFsmIdle, rxRegcopy" *)
    (* descending_urgency = "updateNAV, rxRegcopy" *)
    //区分目的地址是否指向自己
    rule rxRegcopy if(lowMacRxReqQ.notEmpty);
        let rxReq = lowMacRxReqQ.first;
        rxReq.status = True;
        if(lowMacRxYesToMEReqQ.notFull) begin
            lowMacRxYesToMEReqQ.enq(rxReq);
        end
        if(lowMacRxNotToMEReqQ.notFull && !isMyFrame(id, rxReq.dstMacId)) begin
            lowMacRxNotToMEReqQ.enq(rxReq);
        end
        lowMacRxReqQ.deq;
        lowMacRxRespQ.enq(GenericResp{});
    endrule

    (* descending_urgency = "txRegcopy, rxRegcopy" *)    
    rule txRegcopy;
        if(highMacTxReqQ.notEmpty && innerhighMacTxReqQ.notFull) begin
            let txReq = highMacTxReqQ.first;
            highMacTxReqQ.deq;
            innerhighMacTxReqQ.enq(txReq);
            if(countDeltaWire == 0) mac_fifoin_count <= mac_fifoin_count + 1;
        end else begin
            if(countDeltaWire < 0) mac_fifoin_count <= mac_fifoin_count - 1;
        end
    endrule


    rule updateNAV;
        if(lowMacRxNotToMEReqQ.notEmpty) begin
            let rxReq = lowMacRxNotToMEReqQ.first;
            // if(isRtsFrame(rxReq.mpduDigest) || isCtsFrame(rxReq.mpduDigest)|| isDataFrame(rxReq.mpduDigest)) begin
            if(isRtsFrame(rxReq.mpduDigest) || isCtsFrame(rxReq.mpduDigest)) begin
                backOffFsm.navctrl.handleFrame(rxReq);       //新增nav逻辑
                $display("[%8d ns] update nav in mac layer, my mac id is %d, src mac id is %d",$time, id,rxReq.srcMacId);
            end
            lowMacRxNotToMEReqQ.deq;
        end
    endrule

        rule dcfFsmIdle if (dcfStateReg == DCF_IDLE);
            let nextTask = nextTaskReg;
            let state = DCF_IDLE;
            ackTimeoutCountReg <= 0;
            // Phy->lowMac接收队列非空, 进入接收处理逻辑
            if (lowMacRxYesToMEReqQ.notEmpty) begin
                // $display("lowMacRxYesToMEReqQ.notEmpty");
                let rxReq = lowMacRxYesToMEReqQ.first;
                if (isMyFrame(id, rxReq.dstMacId) && isDataFrame(rxReq.mpduDigest)) begin
                    // 收到Data帧，需要回复ACK，先退避SIFS
                    nextTask = NT_SEND_ACK;
                    state = DCF_WAIT_BACKOFF;
                    backOffFsm.start(tuple2(True, False)); //SIFS 
                    rxReq.status = True;
                    highMacRxReqQ.enq(rxReq);
                    $display("[%8d ns] recv data pkt in mac layer, my mac id is %d, dst mac id is %d",$time, id,rxReq.dstMacId);
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Receive DATA", id));
                end
                else if (isMyFrame(id, rxReq.dstMacId) && isRtsFrame(rxReq.mpduDigest)) begin
                    // 收到RTS帧，需要回复CTS，先退避SIFS
                    nextTask = NT_SEND_CTS;
                    state = DCF_WAIT_BACKOFF;
                    backOffFsm.start(tuple2(True, False)); //SIFS 
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Receive RTS", id));
                end 
                else begin
                    // 直接丢弃
                    lowMacRxYesToMEReqQ.deq;
                    // $display("throw pkt in mac layer, my mac id is %d, dst mac id is %d", id,rxReq.dstMacId);
                    // lowMacRxRespQ.enq(GenericResp{});
                    // else do nothing.
                end
            end
            // highMac->lowMac发送队列非空，进入发送处理逻辑，可能需要发送Data或者RTS
            else if (innerhighMacTxReqQ.notEmpty) begin
                // if (backOffFsm.available) begin
                    if (nextTaskReg == NT_IDLE) begin
                    // 一次新的发送/重传
                        backOffFsm.start(tuple2(False, True)); //DIFS and expBackOff
                        let txReq = innerhighMacTxReqQ.first;
                        // 长帧使用RTS
                        if (txReq.mpduDigest.length > macCfgReg.rtsThreshold) begin
                            nextTask = NT_SEND_RTS;
                        end
                        else begin
                            nextTask = NT_SEND_DATA;
                            ctsTimeoutCountReg <= 0;
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
        rule updateCtlFramPower(dcfStateReg == DCF_IDLE && innerhighMacTxReqQ.notEmpty);
            begin
            lasthighMacTxReq <= innerhighMacTxReqQ.first;
            // immLog("mkMacDcf", "updatepower", $format("Id %5d, update power:%d", id, lasthighMacTxReq.rfParam.power));
            end
        endrule

        // 等待退避机制结束
        rule dcfWaitBackOff if (dcfStateReg == DCF_WAIT_BACKOFF);
            if (backOffFsm.done) begin
                case (nextTaskReg)
                NT_SEND_RTS: begin
                    // 第一次BackOff，发送RTS帧
                    let refFrame = innerhighMacTxReqQ.first;
                    let rtsFrame = setRtsFrame(refFrame);//隐藏条件，用refFrame中的NAV数值
                    lowMacTxReqQ.enq(rtsFrame);
                    dcfStateReg <= DCF_RECV_CTSACK;
                    nextTaskReg <= NT_RECV_CTS;
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Send RTS", id));
                    $display("[%8d ns] send rts pkt in mac layer, my mac id is %d, dst mac id is %d",$time, id,refFrame.dstMacId);
                    ctsTimeoutCountReg <= 0;
                    end
                NT_SEND_DATA: begin
                    if(ctsTimeoutCountReg >= macCfgReg.timeout) begin
                        dcfStateReg <= DCF_IDLE;
                        nextTaskReg <= NT_IDLE;
                        if (retransCountReg < macCfgReg.retryLimit) begin
                            retransCountReg <= retransCountReg + 1;
                            backOffFsm.incrCW;  // 失败后增大退避窗口
                            immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Timeout, Retransmit in send data duration", id));
                        end 
                        // 超过重试次数，发送失败
                        else begin
                            retransCountReg <= 0;
                            backOffFsm.resetCW;  // 重置窗口
                            innerhighMacTxReqQ.deq;
                            countDeltaWire <= -1;
                            let txReq = innerhighMacTxReqQ.first;
                            // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Retransmit Time %d, Drop", id, retransCountReg));
                            txReq.status = False;
                            // highMacRxReqQ.enq(txReq);
                        end
                    end
                    else begin
                    // 已经收到过CTS，或者无需RTS/CRS, 发送Data
                        let refFrame = innerhighMacTxReqQ.first;
                        refFrame.mpduDigest.duration = macCfgReg.sifs+ fromInteger(valueOf(CYNC_MPDU_TIME_us)) + fromInteger(valueOf(ACK_MPDU_TIME_us));//待完善 10： SIFS; 48: synctime;  20: acktime
                        lowMacTxReqQ.enq(refFrame);
                        dcfStateReg <= DCF_RECV_CTSACK;
                        nextTaskReg <= NT_RECV_ACK;
                        // immLog("mkMacDcf", "dcfFSM", $format("[%8d ns] Id %5d, Send Data", id, id));
                        $display("[%8d ns] send data pkt in mac layer, my mac id is %d, dst mac id is %d",$time, id,refFrame.dstMacId);
                    end
                    ctsTimeoutCountReg <= 0;
                end
                NT_SEND_CTS: begin
                    // 回复CTS
                    let refFrame = lowMacRxYesToMEReqQ.first;
                    refFrame.rfParam.power = lasthighMacTxReq.rfParam.power;
                    refFrame.mpduDigest.duration = (refFrame.mpduDigest.duration > (macCfgReg.sifs + fromInteger(valueOf(CYNC_MPDU_TIME_us)) + fromInteger(valueOf(RTS_MPDU_TIME_us)))) ? refFrame.mpduDigest.duration - (macCfgReg.sifs + fromInteger(valueOf(CYNC_MPDU_TIME_us)) + fromInteger(valueOf(RTS_MPDU_TIME_us))) : 0;
                    lowMacRxYesToMEReqQ.deq;
                    // lowMacRxRespQ.enq(GenericResp{});
                    let ctsFrame = setCtsFrame(id, refFrame);
                    lowMacTxReqQ.enq(ctsFrame);
                    dcfStateReg <= DCF_IDLE;
                    nextTaskReg <= NT_RECV_DATA;
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Send CTS", id));
                    $display("[%8d ns] send cts pkt in mac layer, my mac id is %d, dst mac id is %d",$time, id,ctsFrame.dstMacId);
                end
                NT_SEND_ACK: begin
                    // 回复ACK
                    if(lowMacRxYesToMEReqQ.notEmpty) begin
                        let refFrame = lowMacRxYesToMEReqQ.first;
                        refFrame.rfParam.power = lasthighMacTxReq.rfParam.power;
                        refFrame.mpduDigest.duration = 0;
                        lowMacRxYesToMEReqQ.deq;
                        // lowMacRxRespQ.enq(GenericResp{});
                        let ackFrame = setAckFrame(id, refFrame);
                        lowMacTxReqQ.enq(ackFrame);
                        dcfStateReg <= DCF_IDLE;
                        nextTaskReg <= NT_IDLE;
                        $display("[%8d ns] send ACK pkt in mac layer, my mac id is %d, dst mac id is %d",$time, id, ackFrame.dstMacId);
                    end
                // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Send ACK", id));
                end
                endcase
            end 
            //需要补充逻辑，就算是在非done部分收到发给自己的帧，也需要处理。回idle重新开始
            else if(ctsTimeoutCountReg != 0)begin
                if (usGen.get)
                    ctsTimeoutCountReg <= ctsTimeoutCountReg + 1;
            end
        endrule

        // 等待对端反馈
        rule dcfRecvCtsAck if (dcfStateReg == DCF_RECV_CTSACK);
            let rxReq = lowMacRxYesToMEReqQ.first;
            let nextTask = nextTaskReg;
            let state = dcfStateReg;
            // if (usGen.get)
            if(ackTimeoutCountReg == 0)begin
                if(phyStatusWire.txEnd == True) begin
                        ackTimeoutCountReg <= ackTimeoutCountReg + 1;
                        $display("reset ackTimeoutCountReg: %d\n", ackTimeoutCountReg);
                end
            end
            if(ackTimeoutCountReg != 0)begin
                if (usGen.get)
                ackTimeoutCountReg <= ackTimeoutCountReg + 1;
            end

            if(ctsTimeoutCountReg == 0)begin
                if(phyStatusWire.txEnd == True) begin
                        ctsTimeoutCountReg <= ctsTimeoutCountReg + 1;
                        $display("reset ctsTimeoutCountReg: %d\n", ctsTimeoutCountReg);
                end
            end
            if(ctsTimeoutCountReg != 0)begin
                if (usGen.get)
                ctsTimeoutCountReg <= ctsTimeoutCountReg + 1;
            end
            
                // ackTimeoutCountReg <= ackTimeoutCountReg + 1;
            if (lowMacRxYesToMEReqQ.notEmpty) begin
                if (isMyFrame(id, rxReq.dstMacId) && isCtsFrame(rxReq.mpduDigest)) begin
                    // 收到了CTS，准备发送DATA
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Receive CTS", id));
                    $display("[%8d ns] recv cts pkt in mac layer, my mac id is %d, src mac id is %d",$time, id,rxReq.srcMacId);
                    lowMacRxYesToMEReqQ.deq;
                    // lowMacRxRespQ.enq(GenericResp{});
                    state = DCF_IDLE;
                    nextTask = NT_SEND_DATA;
                end
                else if (isMyFrame(id, rxReq.dstMacId) && isAckFrame(rxReq.mpduDigest)) begin
                    // 收到了ACK，结束一次发送
                    // TODO: Block ACK 如何处理？？
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Receive ACK", id));
                    $display("[%8d ns] recv ACK pkt in mac layer, my mac id is %d, src mac id is %d",$time, id,rxReq.srcMacId);
                    lowMacRxYesToMEReqQ.deq;
                    // lowMacRxRespQ.enq(GenericResp{});
                    backOffFsm.resetCW;  // 重置窗口
                    nextTask = NT_IDLE;
                    state = DCF_IDLE;
                    innerhighMacTxReqQ.deq;
                    countDeltaWire <= -1;
                    highMacTxRespQ.enq(GenericResp{});
                    retransCountReg <= 0;
                end
                else begin
                    lowMacRxYesToMEReqQ.deq;
                    // lowMacRxRespQ.enq(GenericResp{});
                    if (retransCountReg < macCfgReg.retryLimit) begin
                        retransCountReg <= retransCountReg + 1;
                        backOffFsm.incrCW;  // 失败后增大退避窗口
                        immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Timeout, Retransmit", id));
                    end 
                    // 超过重试次数，发送失败
                    else begin
                        retransCountReg <= 0;
                        backOffFsm.resetCW;  // 重置窗口
                        innerhighMacTxReqQ.deq;
                        countDeltaWire <= -1;
                        let txReq = innerhighMacTxReqQ.first;
                        txReq.status = False;
                    end
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
                    innerhighMacTxReqQ.deq;
                    countDeltaWire <= -1;
                    let txReq = innerhighMacTxReqQ.first;
                    // immLog("mkMacDcf", "dcfFSM", $format("Id %5d, Retransmit Time %d, Drop", id, retransCountReg));
                    txReq.status = False;
                    // highMacRxReqQ.enq(txReq);
                end
                //更新NAV
            end
            dcfStateReg <= state;
            nextTaskReg <= nextTask;
        endrule

    // rule handlemacConfig;
    //     if(macConfigReqQ.notEmpty) begin
    //         let req = macConfigReqQ.first;
    //         macConfigReqQ.deq;
    //         case(req.macReqTag.rwMode)
    //             MOD_WRITE: begin
    //                 macCfgReg <= req.macConfig;
    //                 let resp = getEmptyMacConfigResp();
    //                 resp.macConfig = req.macConfig;
    //                 macConfigRespQ.enq(resp);
    //             end
    //             MOD_READ: begin
    //                 let resp = getEmptyMacConfigResp();
    //                 resp.macConfig = macCfgReg;
    //                 macConfigRespQ.enq(resp);
    //             end
    //         endcase
    //     end
    // endrule

    // rule handlemacStatus;
    //     if(macStatusReqQ.notEmpty) begin
    //         let req = macStatusReqQ.first;
    //         macStatusReqQ.deq;
    //         let resp = getEmptyMacStatusResp();
    //         resp.dcfState    = dcfStateReg;
    //         resp.dcfNextTask = nextTaskReg;
    //         macStatusRespQ.enq(resp);
    //     end
    // endrule

    // 寄存器访问处理规则
    (* descending_urgency = "handleMacRegAccess, dcfFsmIdle, dcfWaitBackOff, dcfRecvCtsAck" *)
    rule handleMacRegAccess;
        let req = macRegReqQ.first;
        macRegReqQ.deq;
        RegAccessResp resp = RegAccessResp{readData: 0, error: False};

        // 寄存器访问逻辑
        case (req.regOffset)
            // MAC 配置寄存器 (可修改)
            mac_slot_time_off: begin
                if (req.writeEnable) macCfgReg.slot <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.slot);
            end
            mac_sifs_off: begin
                if (req.writeEnable) macCfgReg.sifs <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.sifs);
            end
            mac_difs_off: begin
                if (req.writeEnable) macCfgReg.difs <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.difs);
            end
            mac_eifs_off: begin
                if (req.writeEnable) macCfgReg.eifs <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.eifs);
            end
            mac_sig_time_off: begin
                if (req.writeEnable) macCfgReg.sigTime <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.sigTime);
            end
            mac_ofdm_symbol_off: begin
                if (req.writeEnable) macCfgReg.ofdmSymbolTime <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.ofdmSymbolTime);
            end
            mac_max_num_off: begin
                if (req.writeEnable) macCfgReg.maxNum <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.maxNum);
            end
            mac_phy_delay_off: begin
                if (req.writeEnable) macCfgReg.phyDelayTime <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.phyDelayTime);
            end
            mac_timeout_off: begin
                if (req.writeEnable) macCfgReg.timeout <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.timeout);
            end
            mac_cw_min_off: begin
                if (req.writeEnable) macCfgReg.cwMin <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.cwMin);
            end
            mac_cw_max_off: begin
                if (req.writeEnable) macCfgReg.cwMax <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.cwMax);
            end
            mac_rts_thresh_off: begin
                if (req.writeEnable) macCfgReg.rtsThreshold <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.rtsThreshold);
            end
            mac_retry_limit_off: begin
                if (req.writeEnable) macCfgReg.retryLimit <= truncate(req.writeData);
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(macCfgReg.retryLimit);
            end
            nav_en_h_off: begin
                if (req.writeEnable) macCfgReg.navEn <= unpack(truncate(req.writeData[0]));
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(pack(macCfgReg.navEn));
            end
            txop_en_h_off: begin
                if (req.writeEnable) macCfgReg.txopEn <= unpack(truncate(req.writeData[0]));
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(pack(macCfgReg.txopEn));
            end
            filter_en_h_off: begin
                if (req.writeEnable) macCfgReg.filterEn <= unpack(truncate(req.writeData[0]));
                resp.readData = req.writeEnable ? zeroExtend(req.writeData) : zeroExtend(pack(macCfgReg.filterEn));
            end
            
            // MAC 状态寄存器 (仅查询)
            mac_backoff_state_off: begin
                resp.readData = zeroExtend(pack(macStaReg.backOffState));
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
            
            default: begin
                resp.error = True;
                $display("[MacCore:%0d] Invalid register offset: 0x%03h", id, req.regOffset);
            end
        endcase
        
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