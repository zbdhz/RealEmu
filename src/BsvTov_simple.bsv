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
import Connectable::*;
import ClientServer::*;
import BRAM::*;
import ROM::*;
import Vector::*;
import FIFOF::*;
import StmtFSM::*;
import FIFO::*;

import BusConversion::*;
import AxiStreamTypes::*;
import Types::*;
import MacCore::*;
import PhyCore::*;
import CsmaUtils::*;
import PrimUtils::*;
import Channel::*;
import Arbitration::*;
import MacBridge::*;
import CfgBridge::*;

// typedef 32 NODE_NUM;
typedef 512 DATA_WIDTH;
typedef 8 BYTE_WIDTH;
typedef TDiv#(DATA_WIDTH, BYTE_WIDTH) KEEP_WIDTH;
typedef 1  TUSER_WIDTH;
typedef 32  CONFIG_WIDTH;

typedef RawAxiStreamMaster#(KEEP_WIDTH, TUSER_WIDTH) DmaAxiMaster;
typedef RawAxiStreamSlave#(KEEP_WIDTH, TUSER_WIDTH)  DmaAxiSlave;

interface RawEmuCore;
    interface DmaAxiMaster dmaAxiMaster;
    interface DmaAxiSlave dmaAxiSlave;
endinterface

(* synthesize *)
module mkRawEmuCore(RawEmuCore);
    let core <- mkEmuCore; //core的get接口转换成axi
    let axiMasterIfc <- mkGetToRawAxiStreamMaster(core.rx,CF);
    let axiSlaveIfc  <- mkPutToRawAxiStreamSlave(core.tx,CF);

    interface dmaAxiMaster = axiMasterIfc;
    interface dmaAxiSlave = axiSlaveIfc;
endmodule

interface EmuCore;
    interface Get#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) rx;
    interface Put#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) tx;

endinterface

(* synthesize *)
module mkEmuCore(EmuCore);

    // ==================== 实例化子模块 ====================
    FIFOF#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) bridge2AxiFifo <- mkFIFOF; // 发送数据缓冲
    FIFOF#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) axi2BridgeFifo <- mkFIFOF; // 接收数据缓冲

    FIFOF#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) axi2BridgeFifo_mac <- mkFIFOF; // 接收数据缓冲
    FIFOF#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) axi2BridgeFifo_cfg <- mkFIFOF; // 接收数据缓冲

    Vector#(NODE_NUM, MacCore) macNodes <- genWithM(compose(mkMacDCF, fromInteger));
    Vector#(NODE_NUM, PhyCore) phyNodes <- genWithM(compose(mkPhyYansWifi, fromInteger));
    Vector#(NODE_NUM, GainLossModel_Ctrl) channels <- replicateM(mkGainLossModelLogDistance);

    MacBridgeIFC macbridge <- mkMacBridge;
    CfgBridgeIFC cfgbridge <- mkCfgBridge;
    ArbiterIFC pollController <- mkArbiter;

    // ====================   节点连接   ====================
    for(Integer i=0; i<valueOf(NODE_NUM); i=i+1) begin
        mkConnection(macNodes[i].lowMacTxClt, phyNodes[i].lowMacTxSrv);
        mkConnection(macNodes[i].lowMacRxSrv, phyNodes[i].lowMacRxClt);
        mkConnection(phyNodes[i].phyTxClt, channels[i].channel.phyTxSrv);
        mkConnection(phyNodes[i].phyRxSrv, channels[i].channel.phyRxClt);
        mkConnection(pollController.phyTxMetaClt[i], channels[i].channel.phyRxMetaSrv);
        mkConnection(pollController.phyRxMetaSrv[i], channels[i].channel.phyTxMetaClt);

        mkConnection(macbridge.macTxClt[i], macNodes[i].highMacTxSrv);
        mkConnection(macbridge.macRxSrv[i], macNodes[i].highMacRxClt);
        
        mkConnection(cfgbridge.chanTxClt[i], channels[i].chanTxSrv);
    end

    rule updatePhyStatus;
        for (Integer i = 0; i < valueof(NODE_NUM); i = i + 1) begin
            let phyStatus = phyNodes[i].getPhyStatus;
            macNodes[i].phyStatus.put(phyStatus);
        end
    endrule

    // 将 MacBridge 数据转发到 AXI 发送接口
    rule forward_macbridge_to_axi;
        let macEvent <- macbridge.pcieRxClt.request.get;
        AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
            tData: zeroExtend(pack(macEvent)),
            tKeep: '1,      // 所有字节有效
            tLast: True,     // 假设每个MAC事件对应一个AXI包
            tUser: 0
        };
        // $display("macbridge rx ok");
        bridge2AxiFifo.enq(axiPkt);  // 存入发送FIFO
    endrule

    //从AXI接收数据并转发到 Bridge
    rule forward_axi_to_bridge; 
        let axiPkt = axi2BridgeFifo.first;
        axi2BridgeFifo.deq;
        if(axi2BridgeFifo_mac.notFull) axi2BridgeFifo_mac.enq(axiPkt);
        if(axi2BridgeFifo_cfg.notFull) axi2BridgeFifo_cfg.enq(axiPkt);
    endrule

    rule forward_axi_to_macbridge; 
        let axiPkt = axi2BridgeFifo_mac.first;
        axi2BridgeFifo_mac.deq;
        MacBridge_TOP macbridge_top = unpack(truncate(axiPkt.tData));
        if(macbridge_top.bridgeTag.control == 0)begin
            if(macbridge_top.macEvent.srcMacId != macbridge_top.macEvent.dstMacId)begin
                macbridge.pcieTxSrv.request.put(macbridge_top.macEvent);
                // $display("macbridge tx ok, srcPhyId:%d, dstPhyId:%d",macbridge_top.macEvent.srcMacId, macbridge_top.macEvent.dstMacId);
            end
        end
    endrule

    rule forward_axi_to_cfgbridge; 
        let axiPkt = axi2BridgeFifo_cfg.first;
        axi2BridgeFifo_cfg.deq;
        CfgBridge_TOP cfgbridge_top = unpack(truncate(axiPkt.tData));
        if(cfgbridge_top.bridgeTag.control == 1)begin
            if(cfgbridge_top.channelCfg.srcPhyId != cfgbridge_top.channelCfg.dstPhyId)begin
                cfgbridge.chanTxSrv.request.put(cfgbridge_top.channelCfg);
                // $display("cfgbridge tx ok, srcPhyId:%d, dstPhyId:%d",cfgbridge_top.channelCfg.srcPhyId, cfgbridge_top.channelCfg.dstPhyId);
            end
        end
    endrule
        
    rule handshake_macbridge;
        let resp_macbridge <- macbridge.pcieTxSrv.response.get;
    endrule

    rule handshake_cfgbridge;
        let resp_cfgbridge <- cfgbridge.chanTxSrv.response.get;
    endrule

    interface rx = toGet(bridge2AxiFifo);  // 绑定发送接口
    interface tx = toPut(axi2BridgeFifo);  // 绑定接收接口
endmodule

// (* synthesize *)
// module mkEmuCore(EmuCore);
//     // ------------ 实例化子模块 ------------
//     FIFOF#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) mac2AxiFifo <- mkFIFOF; // 发送数据缓冲
//     FIFOF#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) axi2MacFifo <- mkFIFOF; // 接收数据缓冲
//     // 定义节点数量
//     Integer numNodes = 2; // 例如2个节点

//     // 创建 MAC 和 PHY 模块的向量
//     Vector#(2, MacCore) macs <- genWithM(mkMacDCF); 
//     Vector#(2, PhyCore) phys <- genWithM(mkPhyYansWifi);

//     // 连接 MAC 和 PHY 的 LowMac 接口
//     for (Integer i = 0; i < numNodes; i = i + 1) begin
//         mkConnection(macs[i].lowMacTxClt, phys[i].lowMacTxSrv);
//         mkConnection(macs[i].lowMacRxSrv, phys[i].lowMacRxClt);
//     end

//     mkConnection(phys[0].phyTxClt, phys[1].phyRxSrv);  // phy0发送→phy1接收
//     mkConnection(phys[1].phyTxClt, phys[0].phyRxSrv);  // phy1发送→phy0接收

//     rule updatePhyStatus;
//         for (Integer i = 0; i < numNodes; i = i + 1) begin
//             let phyStatus = phys[i].getPhyStatus;
//             macs[i].phyStatus.put(phyStatus);
//         end
//     endrule

//     // 示例：将MAC层数据转发到AXI发送接口
//     rule forward_mac_to_axi;
//         let macEvent <- macs[1].highMacRxClt.request.get();
//         AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
//             tData: zeroExtend(pack(macEvent)),
//             tKeep: '1,      // 所有字节有效
//             tLast: True,     // 假设每个MAC事件对应一个AXI包
//             tUser: 0
//         };
//         mac2AxiFifo.enq(axiPkt);  // 存入发送FIFO
//     endrule

//     // 示例：从AXI接收数据并转发到MAC层
//     rule forward_axi_to_mac;
        
//         let axiPkt = axi2MacFifo.first;
//         axi2MacFifo.deq;

//         MacEvent macEvent = unpack(truncate(axiPkt.tData));
        
//         /*
//         let txReq = getDefaultMacEvent;
//         txReq.srcMacId = 0;
//         txReq.dstMacId = 1;
//         txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
//         txReq.mpduDigest.length = 2048;
//         */
//         macs[0].highMacTxSrv.request.put(macEvent);
//     endrule

//     interface tx = toGet(mac2AxiFifo);  // 绑定发送接口
//     interface rx = toPut(axi2MacFifo);  // 绑定接收接口
// endmodule

// (* synthesize *)
// module mkRawEmuCore(RawEmuCore);
//     let core <- mkEmuCore; //core的get接口转换成axi
//     let axiMasterIfc <- mkGetToRawAxiStreamMaster(core.tx,CF);
//     let axiSlaveIfc  <- mkPutToRawAxiStreamSlave(core.rx,CF);

//     //FIFOF#(Bit#(CONFIG_WIDTH)) configFifo <- mkFIFOF;
//     //let axiLiteSlaveIfc <- mkRawAxi4LiteSlave(toPut(configFifo));
//     /*
//     rule forwardConfig;
//         let cfg <- toGet(configFifo).get;
//         core.configReg.put(cfg);
//     endrule
//     */
//     interface dmaAxiMaster = axiMasterIfc;
//     interface dmaAxiSlave = axiSlaveIfc;
//     //interface dmaAxiLiteSlave = axiLiteSlaveIfc;
// endmodule

// interface EmuCore;
//     interface Get#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) tx;
//     interface Put#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) rx;
//     //interface Put#(Bit#(CONFIG_WIDTH)) configReg;
// endinterface

// (* synthesize *)
// module mkEmuCore(EmuCore);
//     // ------------ 实例化子模块 ------------
//     FIFOF#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) mac2AxiFifo <- mkFIFOF; // 发送数据缓冲
//     FIFOF#(AxiStream#(KEEP_WIDTH, TUSER_WIDTH)) axi2MacFifo <- mkFIFOF; // 接收数据缓冲
//     // 定义节点数量
//     Integer numNodes = 2; // 例如2个节点

//     // 创建 MAC 和 PHY 模块的向量
//     Vector#(2, MacCore) macs <- genWithM(mkMacDCF); 
//     Vector#(2, PhyCore) phys <- genWithM(mkPhyYansWifi);

//     // 连接 MAC 和 PHY 的 LowMac 接口
//     for (Integer i = 0; i < numNodes; i = i + 1) begin
//         mkConnection(macs[i].lowMacTxClt, phys[i].lowMacTxSrv);
//         mkConnection(macs[i].lowMacRxSrv, phys[i].lowMacRxClt);
//     end

//     mkConnection(phys[0].phyTxClt, phys[1].phyRxSrv);  // phy0发送→phy1接收
//     mkConnection(phys[1].phyTxClt, phys[0].phyRxSrv);  // phy1发送→phy0接收

//     rule updatePhyStatus;
//         for (Integer i = 0; i < numNodes; i = i + 1) begin
//             let phyStatus = phys[i].getPhyStatus;
//             macs[i].phyStatus.put(phyStatus);
//         end
//     endrule

//     // 示例：将MAC层数据转发到AXI发送接口
//     rule forward_mac_to_axi;
//         let macEvent <- macs[1].highMacRxClt.request.get();
//         AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
//             tData: zeroExtend(pack(macEvent)),
//             tKeep: '1,      // 所有字节有效
//             tLast: True,     // 假设每个MAC事件对应一个AXI包
//             tUser: 0
//         };
//         mac2AxiFifo.enq(axiPkt);  // 存入发送FIFO
//     endrule

//     // 示例：从AXI接收数据并转发到MAC层
//     rule forward_axi_to_mac;
        
//         let axiPkt = axi2MacFifo.first;
//         axi2MacFifo.deq;

//         MacEvent macEvent = unpack(truncate(axiPkt.tData));
        
//         /*
//         let txReq = getDefaultMacEvent;
//         txReq.srcMacId = 0;
//         txReq.dstMacId = 1;
//         txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
//         txReq.mpduDigest.length = 2048;
//         */
//         macs[0].highMacTxSrv.request.put(macEvent);
//     endrule

//     interface tx = toGet(mac2AxiFifo);  // 绑定发送接口
//     interface rx = toPut(axi2MacFifo);  // 绑定接收接口
// endmodule