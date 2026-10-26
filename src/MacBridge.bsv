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



// typedef TLog#(NODE_NUM) NodeIdWidth;  // 10 bits

// typedef TDiv#(TLog#(NODE_NUM), TLog#(GROUP_SIZE)) TreeDepth;  // log32(1024)=2

typedef enum {MuxBegin, MuxEnd} MuxState deriving (Bits, Eq);

interface MacBridgeIFC;

    interface MacSrv pcieTxSrv; // 下行 (pcie -> macbridge -> mac) (srv提供服务处理收到的包)
    interface MacClt pcieRxClt; // 上行 (mac -> macbridge -> pcie) (clt作为客户发包提需求)

    interface Vector#(NODE_NUM, MacSrv)  macRxSrv;  // 连接所有节点的 highMacRxClt (上行收包)
    interface Vector#(NODE_NUM, MacClt)  macTxClt;  // 连接所有节点的 highMacTxSrv (下行发包)

endinterface



(* synthesize *)
module mkMacBridge(MacBridgeIFC);
    ///////////////////////////////////////////////////////////////////////////
    // 接口FIFO
    ///////////////////////////////////////////////////////////////////////////

    FIFOF#(MacEvent)    pcieTxReqQ  <- mkFIFOF;
    FIFOF#(GenericResp) pcieTxRespQ <- mkFIFOF;
    FIFOF#(MacEvent)    pcieRxReqQ  <- mkFIFOF;
    FIFOF#(GenericResp) pcieRxRespQ <- mkFIFOF;

    Vector#(NODE_NUM, FIFOF#(MacEvent))    qMacTxReqQ   <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(GenericResp)) qMacTxRespQ  <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(MacEvent))    qMacRxReqQ   <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(GenericResp)) qMacRxRespQ  <- replicateM(mkFIFOF);

    ///////////////////////////////////////////////////////////////////////////
    // 轮询控制逻辑（保持原始结构）
    ///////////////////////////////////////////////////////////////////////////
    // C02: 上传队列保留选中事件，直到 PCIe 输出 FIFO 真正接受。
    FIFOF#(MacEvent) deMuxReg1 <- mkFIFOF;
    // Reg#(Tuple2#(Bool, MacEvent)) deMuxRegs <- mkDReg(tuple2(False, getEmptyMacEvent));

    ///////////////////////////////////////////////////////////////////////////
    // 32叉树聚合逻辑
    ///////////////////////////////////////////////////////////////////////////
    Reg#(MuxState) rxmuxState <- mkReg(MuxBegin);
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(MacId))    macIdRegs1  <- replicateM(mkReg(0));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(Bool))     validRegs1 <- replicateM(mkReg(False));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(MacEvent)) eventRegs1 <- replicateM(mkReg(getEmptyMacEvent));

    // Level 1 MUX（32节点→1节点）
    rule muxBegin if (rxmuxState == MuxBegin);
        Bool valid = False;
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            Bool groupValid = False;
            Integer groupId = 0;
            MacEvent groupEvent = getEmptyMacEvent;
            
            // 扫描32个子节点
            for (Integer i = 0; i < valueOf(GROUP_SIZE); i = i + 1) begin
                let nodeId = g * valueOf(GROUP_SIZE) + i;
                if (qMacRxReqQ[nodeId].notEmpty) begin
                    groupValid = True;
                    let macRxReq = qMacRxReqQ[nodeId].first;
                    groupEvent = macRxReq;  // 取最后一个有效事件
                    groupId = nodeId;  // 记录组ID
                    //$display("%d",nodeId);
                end
            end
            validRegs1[g] <= groupValid;
            eventRegs1[g] <= groupEvent;
            macIdRegs1[g] <= fromInteger(groupId); 
            if(groupValid)begin
                valid = groupValid;  // 至少有一个组有效
            end
        end
        if(valid)begin
            rxmuxState <= MuxEnd;  // 没有有效事件，直接结束
        end 
    endrule

    // Level 2 MUX（32组→1个全局）
    rule muxEnd if (rxmuxState == MuxEnd);
        MacId selectId = 0;  // 用于记录物理ID
        Bool finalValid = False;
        MacEvent finalEvent = getEmptyMacEvent;
        
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            if (validRegs1[g]) begin
                finalValid = True;
                finalEvent = eventRegs1[g];  // 取最后一个有效事件
                selectId = macIdRegs1[g];  // 记录物理ID
            end
        end

        if (finalValid) deMuxReg1.enq(finalEvent);
        rxmuxState <= MuxBegin;
        if(finalValid && qMacRxReqQ[selectId].notEmpty)begin
            qMacRxReqQ[selectId].deq;
            qMacRxRespQ[selectId].enq(GenericResp{});
            // $display("rx_level_2: %x", finalEvent);
        end
    endrule

    ///////////////////////////////////////////////////////////////////////////
    // 32叉树聚合上传
    ///////////////////////////////////////////////////////////////////////////

    rule rxupload;
        pcieRxReqQ.enq(deMuxReg1.first);
        deMuxReg1.deq;
    endrule

    rule handshakeRx;
        pcieRxRespQ.deq;
    endrule
    ///////////////////////////////////////////////////////////////////////////
    // 32叉树分散下传
    ///////////////////////////////////////////////////////////////////////////
    //代办：增加有效的数据判断，所有事件下发时为valid-ture，不处理则为非
    // Reg#(MacEvent)) deMuxReg2 <- mkDReg(getEmptyMacEvent);
    // Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(MacEvent)) eventRegs2 <- replicateM(mkReg(getEmptyMacEvent));
    // Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(Bool))     validRegs2 <- replicateM(mkReg(False));
    // C02: 两级下传保持原路径，FIFO 自然传播背压，valid 不再只保持一拍。
    FIFOF#(MacEvent) txStage1 <- mkFIFOF;
    FIFOF#(MacEvent) txStage2 <- mkFIFOF;
    rule txProcess;
        txStage1.enq(pcieTxReqQ.first);
        pcieTxReqQ.deq;
        pcieTxRespQ.enq(GenericResp{});
    endrule
    rule txBroadcast;
        txStage2.enq(txStage1.first);
        txStage1.deq;
    endrule
    rule txSend;
        let evt = txStage2.first;
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
            if (evt.srcMacId == fromInteger(i)) qMacTxReqQ[i].enq(evt);
        end
        txStage2.deq;
    endrule

    for(Integer i = 0; i < valueOf(NODE_NUM); i = i + 1)begin
        rule handshakeTx;
            qMacTxRespQ[i].deq;
        endrule
    end

    ///////////////////////////////////////////////////////////////////////////
    // 接口连接
    ///////////////////////////////////////////////////////////////////////////

    Vector#(NODE_NUM, MacSrv)  highMacRxSrv; 
    Vector#(NODE_NUM, MacClt)  highMacTxClt;



    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        highMacRxSrv[i] = toGPServer(qMacRxReqQ[i], qMacRxRespQ[i]);
        highMacTxClt[i] = toGPClient(qMacTxReqQ[i], qMacTxRespQ[i]);
    end

    interface pcieTxSrv = toGPServer(pcieTxReqQ, pcieTxRespQ);
    interface pcieRxClt = toGPClient(pcieRxReqQ, pcieRxRespQ);
    interface macTxClt = highMacTxClt;
    interface macRxSrv = highMacRxSrv;
endmodule