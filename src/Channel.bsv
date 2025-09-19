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


import ClientServer::*;
import RegFile::*;
import Vector::*;
import FIFO::*;
import BRAM::*;

import Types::*;
import MathUtils::*;
import ROM::*;

typedef 5 FSModelPipeDepth;

/* LogDistance Channel, gain loss ~ 20log(distance) between nodes
 * L = L0 + 10nlog((d)/(d0)), where d0 is set as 1m, n = 2 for free space case
 * L0 and d0 are read from system register block
 */

 interface GainLossModel;
    interface PhySrv phyTxSrv;
    interface PhyClt phyRxClt; //与phy相连,tx直连 rx计算衰减

    interface PhyClt phyTxMetaClt;
    interface PhySrv phyRxMetaSrv; //与arbitration相连
endinterface

// 新的复合接口，包含原有的GainLossModel接口和控制接口

interface GainLossModel_Ctrl;
    interface GainLossModel channel;
    // interface BRAMServer#(Bit#(DEV_ID_WIDTH), NodeDistance) configPort;
    interface ChanSrv chanTxSrv;
endinterface
// interface ConfigPort;
//     interface BRAMServer#(Bit#(DEV_ID_WIDTH), NodeDistance) configPort;
// endinterface
// interface BRAM_DUAL_PORT#(type addr, type data);   // 双口 RAM 接口

// (* synthesize *)
// module mkGainLossModelIdeal#(Integer id)(GainLossModel);
module mkGainLossModelIdeal(GainLossModel);
    FIFO#(PhyEvent)    phyTxReqQ   <- mkFIFO;
    FIFO#(GenericResp) phyTxRespQ  <- mkFIFO;
    FIFO#(PhyEvent)    phyRxReqQ   <- mkFIFO;
    FIFO#(GenericResp) phyRxRespQ  <- mkFIFO;

    FIFO#(PhyEvent)    txReqQ  <- mkFIFO;
    FIFO#(GenericResp) txRespQ <- mkFIFO;
    FIFO#(PhyEvent)    rxReqQ  <- mkFIFO;
    FIFO#(GenericResp) rxRespQ <- mkFIFO;

    rule phyTx;
        let phyTxReq = phyTxReqQ.first;
        phyTxReqQ.deq;
        phyTxRespQ.enq(GenericResp{});
        txReqQ.enq(phyTxReq);
    endrule

    // forward the meta directly, do not modify power
    rule forward;
        let phyrxReq = rxReqQ.first;
        rxReqQ.deq;
        rxRespQ.enq(GenericResp{});
        phyRxReqQ.enq(phyrxReq);
    endrule

    rule handshakeTx;
        txRespQ.deq;
    endrule

    rule handshakeRx;
       phyRxRespQ.deq;
    endrule

    // rule handshakeRx;
    //     phyRxRespQ.deq;
    // endrule

    interface phyTxSrv    = toGPServer(phyTxReqQ, phyTxRespQ);
    interface phyRxClt    = toGPClient(phyRxReqQ, phyRxRespQ);

    interface phyTxMetaClt = toGPClient(txReqQ, txRespQ);
    interface phyRxMetaSrv = toGPServer(rxReqQ, rxRespQ);
endmodule


module mkGainLossModelLogDistance(GainLossModel_Ctrl);
    FIFO#(PhyEvent)    phyTxReqQ   <- mkFIFO;
    FIFO#(GenericResp) phyTxRespQ  <- mkFIFO;
    FIFO#(PhyEvent)    phyRxReqQ   <- mkFIFO;
    FIFO#(GenericResp) phyRxRespQ  <- mkFIFO;

    FIFO#(PhyEvent)    txReqQ  <- mkFIFO;
    FIFO#(GenericResp) txRespQ <- mkFIFO;
    FIFO#(PhyEvent)    rxReqQ  <- mkFIFO;
    FIFO#(GenericResp) rxRespQ <- mkFIFO;

    FIFO#(ChannelCfg)  chancfgTxReqQ   <- mkFIFO;
    FIFO#(GenericResp) chancfgTxRespQ  <- mkFIFO;

    FIFO#(PhyEvent)    txPipeQ   <- mkSizedFIFO(valueOf(FSModelPipeDepth));
    Rom1port#(NodeDistance,UInt#(12)) lossTable <- mkSingleRom("20lgd.mem");

    //FIFO#(NodeDistance) distPipeQ <- mkSizedFIFO(valueOf(FSModelPipeDepth));  

    //ram的外部定义，需要暴露另一端口给DMA配置  d:10
    BRAM2Port#(Bit#(DEV_ID_WIDTH), NodeDistance) distanceRam2 <- mkBRAM2Server(
        // defaultValue
        BRAM_Configure {                            
            memorySize   : 0,                       
            loadFormat   : tagged Hex "bram_one.txt",
            // loadFormat   : tagged Hex filename_location,      
            latency      : 2,                          
            outFIFODepth : 4,                          
            allowWriteResponseBypass : False           
        }
    );


    //将phyTxReqQ直接写入txReqQ，等待arbiter调度
    rule phyTx;
        let phyTxReq = phyTxReqQ.first;
        phyTxReqQ.deq;
        phyTxRespQ.enq(GenericResp{});
        txReqQ.enq(phyTxReq);
    endrule

    rule queryDistance; //处理与arbiter的接口rxReqQ
        let phyTxReq = rxReqQ.first;
        rxReqQ.deq;
        rxRespQ.enq(GenericResp{});
        txPipeQ.enq(phyTxReq);
        let bramReq = BRAMRequest{             
            write: False,          
            responseOnWrite: False,  
            address:  phyTxReq.srcPhyId,            
            datain: 0             
        };
        distanceRam2.portB.request.put(bramReq);
    endrule

    //目前仿真默认读出的距离为682 而32*20lg(682) = 1814 仿真结果正确
    rule queryLoss;
        let distance <- distanceRam2.portB.response.get;
        lossTable.request.put(unpack(distance));
        // $display("diatance:%d",distance);
    endrule

    //loss = 20lg(d);
    rule getLoss;
        let loss <- lossTable.response.get;  
        let phyTxReq = txPipeQ.first;
        txPipeQ.deq;
        let txPower = phyTxReq.rfParam.power;
        let rxPower = txPower - unpack(pack(loss));  // power is signed, loss is unsigned
        // $display("phyTxReq.srcid:%d, phyTxReq.dstId:%d, pathloss:%d",phyTxReq.srcPhyId,phyTxReq.dstPhyId,unpack(pack(loss)));
        phyTxReq.rfParam.power = rxPower;
        phyRxReqQ.enq(phyTxReq);
    endrule
    
    //更新channel配置
    rule updateChannelConfig;
        let chancfg = chancfgTxReqQ.first;
        chancfgTxReqQ.deq;
        chancfgTxRespQ.enq(GenericResp{});
        let bramReq = BRAMRequest {
                write: True,
                responseOnWrite: False,
                address: truncate(pack(chancfg.srcPhyId)),
                datain: truncate(pack(chancfg.distance))
            };
        distanceRam2.portA.request.put(bramReq);
        $display("channel config: srcPhyId=%d, dstPhyId=%d, distance=%d", chancfg.srcPhyId, chancfg.dstPhyId, chancfg.distance);
    endrule

    rule handshakeRx;
        phyRxRespQ.deq;
    endrule

    rule handshakeTx;
        txRespQ.deq;
    endrule

    

    interface GainLossModel channel;
        // 实现GainLossModel子接口
        interface phyTxSrv    = toGPServer(phyTxReqQ, phyTxRespQ);
        interface phyRxClt    = toGPClient(phyRxReqQ, phyRxRespQ);
        interface phyTxMetaClt = toGPClient(txReqQ, txRespQ);
        interface phyRxMetaSrv = toGPServer(rxReqQ, rxRespQ);
    endinterface

    //实现ChannelCfg子接口
    interface chanTxSrv    = toGPServer(chancfgTxReqQ, chancfgTxRespQ);
    // 暴露BRAM端口A作为配置接口
    // interface configPort = distanceRam2.portA;

endmodule

// module mkGainLossModelLogDistance
// // #(
// // String filename_location
// // )
// // #(
// //     BRAM2Port#(PhyId, NodeDistance) distanceRam2
// //     // RegBlock regBlock                                   
// // )
// (GainLossModel);
//     FIFO#(PhyEvent)    phyTxReqQ   <- mkFIFO;
//     FIFO#(GenericResp) phyTxRespQ  <- mkFIFO;
//     FIFO#(PhyEvent)    phyRxReqQ   <- mkFIFO;
//     FIFO#(GenericResp) phyRxRespQ  <- mkFIFO;

//     FIFO#(PhyEvent)    txReqQ  <- mkFIFO;
//     FIFO#(GenericResp) txRespQ <- mkFIFO;
//     FIFO#(PhyEvent)    rxReqQ  <- mkFIFO;
//     FIFO#(GenericResp) rxRespQ <- mkFIFO;

//     FIFO#(PhyEvent)    txPipeQ   <- mkSizedFIFO(valueOf(FSModelPipeDepth));
//     Rom1port#(NodeDistance,UInt#(12)) lossTable <- mkSingleRom("20lgd.mem");

//     //FIFO#(NodeDistance) distPipeQ <- mkSizedFIFO(valueOf(FSModelPipeDepth));  

//     //ram的外部定义，需要暴露另一端口给DMA配置  d:10
//     BRAM2Port#(Bit#(DEV_ID_WIDTH), NodeDistance) distanceRam2 <- mkBRAM2Server(
//         // defaultValue
//         BRAM_Configure {                            
//             memorySize   : 0,                       
//             loadFormat   : tagged Hex "bram_one.txt",
//             // loadFormat   : tagged Hex filename_location,      
//             latency      : 2,                          
//             outFIFODepth : 4,                          
//             allowWriteResponseBypass : False           
//         }
//     );

//     //外部配置接口
//     // rule updateParam;
//     //     param <= regBlock.logDistanceChannelParam.get;
//     // endrule

//     //将phyTxReqQ直接写入txReqQ，等待arbiter调度
//     rule phyTx;
//         let phyTxReq = phyTxReqQ.first;
//         phyTxReqQ.deq;
//         phyTxRespQ.enq(GenericResp{});
//         txReqQ.enq(phyTxReq);
//     endrule

//     rule queryDistance; //处理与arbiter的接口rxReqQ
//         let phyTxReq = rxReqQ.first;
//         rxReqQ.deq;
//         rxRespQ.enq(GenericResp{});
//         txPipeQ.enq(phyTxReq);
//         let bramReq = BRAMRequest{             
//             write: False,          
//             responseOnWrite: False,  
//             address:  phyTxReq.srcPhyId,            
//             datain: 0             
//         };
//         distanceRam2.portB.request.put(bramReq);
//     endrule

//     //目前仿真默认读出的距离为682 而32*20lg(682) = 1814 仿真结果正确
//     rule queryLoss;
//         let distance <- distanceRam2.portB.response.get;
//         lossTable.request.put(unpack(distance));
//         // $display("diatance:%d",distance);
//     endrule

//     //loss = 20lg(d);
//     rule getLoss;
//         let loss <- lossTable.response.get;  
//         let phyTxReq = txPipeQ.first;
//         txPipeQ.deq;
//         let txPower = phyTxReq.rfParam.power;
//         let rxPower = txPower - unpack(pack(loss));  // power is signed, loss is unsigned
//         // $display("pathloss:%d",unpack(pack(loss)));
//         phyTxReq.rfParam.power = rxPower;
//         phyRxReqQ.enq(phyTxReq);
//     endrule

//     rule handshakeRx;
//         phyRxRespQ.deq;
//     endrule

//     rule handshakeTx;
//         txRespQ.deq;
//     endrule

//     interface phyTxSrv    = toGPServer(phyTxReqQ, phyTxRespQ);
//     interface phyRxClt    = toGPClient(phyRxReqQ, phyRxRespQ);

//     interface phyTxMetaClt = toGPClient(txReqQ, txRespQ);
//     interface phyRxMetaSrv = toGPServer(rxReqQ, rxRespQ);
// endmodule
