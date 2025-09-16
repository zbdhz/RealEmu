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
    Reg#(Tuple2#(Bool, MacEvent)) deMuxReg1 <- mkDReg(tuple2(False, getEmptyMacEvent));
    // Reg#(Tuple2#(Bool, MacEvent)) deMuxRegs <- mkDReg(tuple2(False, getEmptyMacEvent));

    ///////////////////////////////////////////////////////////////////////////
    // 32叉树聚合逻辑
    ///////////////////////////////////////////////////////////////////////////
    Reg#(MuxState) rxmuxState <- mkReg(MuxBegin);
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(MacId))    macIdRegs1  <- replicateM(mkDReg(0));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(Bool))     validRegs1 <- replicateM(mkDReg(False));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(MacEvent)) eventRegs1 <- replicateM(mkDReg(getEmptyMacEvent));

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

        deMuxReg1 <= tuple2(finalValid, finalEvent);
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
        let {valid, rxEvent} = deMuxReg1;
        if(valid)begin
            pcieRxReqQ.enq(rxEvent);
            // $display("rx_upload: %x", rxEvent);
        end
    
    endrule

    rule handshakeRx;
        pcieRxRespQ.deq;
    endrule
    ///////////////////////////////////////////////////////////////////////////
    // 32叉树分散下传
    ///////////////////////////////////////////////////////////////////////////
    //代办：增加有效的数据判断，所有事件下发时为valid-ture，不处理则为非
    // Reg#(MacEvent)) deMuxReg2 <- mkDReg(getEmptyMacEvent);
    // Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(MacEvent)) eventRegs2 <- replicateM(mkDReg(getEmptyMacEvent));
    // Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(Bool))     validRegs2 <- replicateM(mkDReg(False));
    Reg#(Tuple2#(Bool, MacEvent)) deMuxReg2 <- mkDReg(tuple2(False, getEmptyMacEvent));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(Bool))     validRegs2 <- replicateM(mkDReg(False));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(MacEvent)) eventRegs2 <- replicateM(mkDReg(getEmptyMacEvent));
    // Level 1 MUX（1节点→32组，粗略广播）
    rule txProcess;
        let txReq = pcieTxReqQ.first;
        pcieTxReqQ.deq;
        // $display("macbrigdge rx ok!!!");
        pcieTxRespQ.enq(GenericResp{});
        deMuxReg2 <= tuple2(True, txReq);
    endrule

    rule txBroadcast;
        let {valid, txEvent} = deMuxReg2;
        // 上游信号广播到各组
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            validRegs2[g] <= valid;
            eventRegs2[g] <= txEvent;
            // $display("macbridge tx_broadcast OK! srcMacId: %x",txEvent.srcMacId);
        end
    endrule

    // Level 2 MUX（各组父节点→子节点，精准匹配）
    rule txSend;
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            for (Integer gr = 0; gr < valueOf(GROUP_SIZE); gr = gr + 1) begin
                let index = g*valueOf(GROUP_SIZE) + gr;
                let valid = validRegs2[g];
                let txEvent = eventRegs2[g];
                if (valid && txEvent.srcMacId == fromInteger(index)) begin
                    qMacTxReqQ[index].enq(txEvent);
                    // $display("macbrigdge tx ok!!!");
                end
            end
        end
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