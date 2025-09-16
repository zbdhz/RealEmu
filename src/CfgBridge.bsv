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

    interface ChanSrv chanTxSrv; // 下行

    interface Vector#(NODE_NUM, ChanClt)  chanTxClt;  // 连接所有节点的 highMacTxSrv (下行发包)

endinterface


(* synthesize *)
module mkCfgBridge(CfgBridgeIFC); 
    // 接口FIFO
    FIFOF#(ChannelCfg)                          pcieTxReqQ   <- mkFIFOF;
    FIFOF#(GenericResp)                         pcieTxRespQ  <- mkFIFOF;
    Vector#(NODE_NUM, FIFOF#(ChannelCfg))       qChanTxReqQ   <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(GenericResp))      qChanTxRespQ  <- replicateM(mkFIFOF);
    //
    Reg#(Tuple2#(Bool, ChannelCfg)) deMuxReg2 <- mkDReg(tuple2(False, getEmptyChannelCfg));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(Bool))     validRegs2 <- replicateM(mkDReg(False));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(ChannelCfg)) eventRegs2 <- replicateM(mkDReg(getEmptyChannelCfg));

    // Level 1 MUX（1节点→32组，粗略广播）
    rule txProcess;
        let txReq = pcieTxReqQ.first;
        pcieTxReqQ.deq;
        pcieTxRespQ.enq(GenericResp{});
        deMuxReg2 <= tuple2(True, txReq);
    endrule

    rule txBroadcast;
        let {valid, txChannelCfg} = deMuxReg2;
        // 上游信号广播到各组
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            validRegs2[g] <= valid;
            eventRegs2[g] <= txChannelCfg;
        end
    endrule

    // Level 2 MUX（各组父节点→子节点，精准匹配）
    rule txSend;
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            for (Integer gr = 0; gr < valueOf(GROUP_SIZE); gr = gr + 1) begin
                let index = g*valueOf(GROUP_SIZE) + gr;
                let valid = validRegs2[g];
                let txChannelCfg = eventRegs2[g];
                if (valid && txChannelCfg.dstPhyId == fromInteger(index)) begin
                    qChanTxReqQ[index].enq(txChannelCfg);
                end
            end
        end
    endrule

    for(Integer i = 0; i < valueOf(NODE_NUM); i = i + 1)begin
        rule handshakeTx;
            qChanTxRespQ[i].deq;
        endrule
    end

    //接口实现
    Vector#(NODE_NUM, ChanClt)  qchanTxClt;

    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        qchanTxClt[i] = toGPClient(qChanTxReqQ[i], qChanTxRespQ[i]);
    end

    interface chanTxSrv = toGPServer(pcieTxReqQ, pcieTxRespQ);//上游

    interface chanTxClt = qchanTxClt;//下游

endmodule