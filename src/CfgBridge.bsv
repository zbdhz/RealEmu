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

//----------------------------------------------------------------------------------
//TreeDepth = 2
//----------------------------------------------------------------------------------
import Vector::*;
import ClientServer::*;
import GetPut::*;
import FIFO::*;
import FIFOF::*;
import RegFile::*;
import DReg::*;
import MathUtils::*;
import Types::*;


interface CfgBridgeIFC;

    interface ChanSrv chanTxSrv; // 下行通道(channelcfg)
    interface PerSrv  perTxSrv;// 下行通道 (percfg)

    interface Vector#(NODE_NUM, ChanClt)  chanTxClt;  // 连接所有节点的 highMacTxSrv (下行发包)
    interface Vector#(NODE_NUM, PerClt)   perTxClt; // 连接所有节点phy层的per配置通道
endinterface


(* synthesize *)
module mkCfgBridge(CfgBridgeIFC); 
    // 接口FIFO
    FIFOF#(ChannelCfg)                          pcieTxReqQ   <- mkFIFOF;
    FIFOF#(GenericResp)                         pcieTxRespQ  <- mkFIFOF;
    Vector#(NODE_NUM, FIFOF#(ChannelCfg))       qChanTxReqQ   <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(GenericResp))      qChanTxRespQ  <- replicateM(mkFIFOF);
    
    FIFOF#(PerCfg)                          pcieTxPerReqQ   <- mkFIFOF;
    FIFOF#(GenericResp)                     pcieTxPerRespQ  <- mkFIFOF;
    Vector#(NODE_NUM, FIFOF#(PerCfg))       qPerTxReqQ   <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(GenericResp))  qPerTxRespQ  <- replicateM(mkFIFOF);

    // C02: 复用原两级分发结构，用 FIFO 保持事件直到下游接受。
    FIFOF#(ChannelCfg) chanStage1 <- mkFIFOF;
    FIFOF#(ChannelCfg) chanStage2 <- mkFIFOF;
    Reg#(Bool) chanWaiting <- mkReg(False);
    Reg#(PhyId) chanTarget <- mkReg(0);

    rule txProcess;
        chanStage1.enq(pcieTxReqQ.first);
        pcieTxReqQ.deq;
    endrule
    rule txBroadcast;
        chanStage2.enq(chanStage1.first);
        chanStage1.deq;
    endrule
    rule txSend (!chanWaiting);
        let cfg = chanStage2.first;
        if (cfg.dstPhyId < fromInteger(valueOf(NODE_NUM))) begin
            for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
                if (cfg.dstPhyId == fromInteger(i)) qChanTxReqQ[i].enq(cfg);
            end
            chanTarget <= cfg.dstPhyId;
            chanWaiting <= True;
        end
        else pcieTxRespQ.enq(GenericResp{}); // 无效节点不产生写入，也不能占住流水。
        chanStage2.deq;
    endrule
    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        rule handshakeTx (chanWaiting && chanTarget == fromInteger(i));
            qChanTxRespQ[i].deq;
            // 响应来自目标 BRAM 写完成，不再把入口接收当成配置生效。
            pcieTxRespQ.enq(GenericResp{});
            chanWaiting <= False;
        endrule
    end

    FIFOF#(PerCfg) perStage1 <- mkFIFOF;
    FIFOF#(PerCfg) perStage2 <- mkFIFOF;
    Reg#(Bool) perWaiting <- mkReg(False);
    Reg#(Bit#(NODE_NUM)) perAckMask <- mkReg(0);
    rule txProcessPer;
        perStage1.enq(pcieTxPerReqQ.first);
        pcieTxPerReqQ.deq;
    endrule
    rule txBroadcastPer;
        perStage2.enq(perStage1.first);
        perStage1.deq;
    endrule
    rule txSendPer (!perWaiting);
        let cfg = perStage2.first;
        // 原子广播：任何节点满都保留整条配置，避免部分投递后的重放/重复。
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1)
            qPerTxReqQ[i].enq(cfg);
        perStage2.deq;
        perWaiting <= True;
        perAckMask <= 0;
    endrule
    rule handshakePerTx (perWaiting);
        Bit#(NODE_NUM) nextMask = perAckMask;
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
            if (qPerTxRespQ[i].notEmpty) begin
                qPerTxRespQ[i].deq;
                nextMask[i] = 1;
            end
        end
        perAckMask <= nextMask;
        if (nextMask == '1) begin
            pcieTxPerRespQ.enq(GenericResp{});
            perWaiting <= False;
        end
    endrule

    //接口实现
    Vector#(NODE_NUM, ChanClt)  qchanTxClt;

    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        qchanTxClt[i] = toGPClient(qChanTxReqQ[i], qChanTxRespQ[i]);
    end

    Vector#(NODE_NUM, PerClt)  qperTxClt;

    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        qperTxClt[i] = toGPClient(qPerTxReqQ[i], qPerTxRespQ[i]);
    end

    interface chanTxSrv = toGPServer(pcieTxReqQ, pcieTxRespQ);//上游channel
    interface perTxSrv  = toGPServer(pcieTxPerReqQ, pcieTxPerRespQ);//上游Per
    interface chanTxClt = qchanTxClt;//下游
    interface perTxClt = qperTxClt;//下游

endmodule