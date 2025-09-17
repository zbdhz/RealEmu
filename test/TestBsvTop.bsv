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
import BsvTop::*;
typedef 8 TEST_NODE_NUM;
function String digitToChar(Integer d);
    case (d)
        0: return "0";
        1: return "1";
        2: return "2";
        3: return "3";
        4: return "4";
        5: return "5";
        6: return "6";
        7: return "7";
        8: return "8";
        9: return "9";
        default: return "?";
    endcase
endfunction

function String intToString(Integer val);
    if (val < 10) begin
        return digitToChar(val);
    end else if (val < 100) begin
        Integer tens = val / 10;
        Integer ones = val % 10;
        return digitToChar(tens) + digitToChar(ones);
    end else if (val < 1000) begin
        Integer hundreds = val / 100;
        Integer rem = val % 100;
        Integer tens = rem / 10;
        Integer ones = rem % 10;
        return digitToChar(hundreds) + digitToChar(tens) + digitToChar(ones);
    end else if (val == 1000) begin
        return "1000";
    end else if (val == 1023) begin
        return "1023";
    end else begin
        return "???";
    end
endfunction

`define BSIM;

module mkTestRawEmuCore(Empty);
    let core <- mkEmuCore;

    Reg#(MacId) sendingNodes <- mkReg(1);     // 总接收包数
    // Reg#(UInt#(10)) sendingNodes <- mkReg(1);     // 总接收包数
    // // 初始化索引
    // Reg#(UInt#(32)) initIdx <- mkReg(0);
    // // 初始化完成标志
    // Reg#(Bool) initialized <- mkReg(False);
    // ==================== 控制寄存器 ====================
    Reg#(UInt#(64)) cycleCount <- mkReg(3);
    Reg#(UInt#(64)) totalReceived <- mkReg(0);     // 总接收包数
    Reg#(File) logFile <- mkReg(InvalidFile);     // 日志文件句柄

    rule initialize (cycleCount == 10);
        let fd <- $fopen("/home/emu/dev/RealEmu/scripts/throughout2.txt", "w");
        logFile <= fd;
    endrule

    // ==================== 时钟计数 ====================
    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    // ==================== 节点连接 ====================
    // for(Integer i=0; i<valueOf(NODE_NUM); i=i+1) begin
    //     mkConnection(macNodes[i].lowMacTxClt, phyNodes[i].lowMacTxSrv);
    //     mkConnection(macNodes[i].lowMacRxSrv, phyNodes[i].lowMacRxClt);
    //     mkConnection(phyNodes[i].phyTxClt, channels[i].channel.phyTxSrv);
    //     mkConnection(phyNodes[i].phyRxSrv, channels[i].channel.phyRxClt);
    //     mkConnection(pollController.phyTxMetaClt[i], channels[i].channel.phyRxMetaSrv);
    //     mkConnection(pollController.phyRxMetaSrv[i], channels[i].channel.phyTxMetaClt);

    //     mkConnection(macbridge.macTxClt[i], macNodes[i].highMacTxSrv);
    //     mkConnection(macbridge.macRxSrv[i], macNodes[i].highMacRxClt);
        
    //     mkConnection(cfgbridge.chanTxClt[i], channels[i].chanTxSrv);
    // end
    
    // rule updatePhyStatus;
    //     for (Integer i = 0; i < valueof(NODE_NUM); i = i + 1) begin
    //         let phyStatus = phyNodes[i].getPhyStatus;
    //         macNodes[i].phyStatus.put(phyStatus);
    //     end
    // endrule

    // 初始化BRAM规则
    // rule initializeBRAM (!initialized);
    //     if (initIdx < fromInteger(valueOf(NODE_NUM))) begin
    //         // 为每个节点设置距离值，这里使用简单的计算方式
    //         let distance = (initIdx < 256) ? 
    //                     1*(1 + initIdx ) : 
    //                     100;

    //         let chancfg = getEmptyChannelCfg;
    //         chancfg.srcPhyId = truncate(pack(initIdx));
    //         chancfg.dstPhyId = 0;
    //         chancfg.distance = truncate(pack(distance));
    //         cfgbridge.chanTxSrv.request.put(chancfg);
    //         initIdx <= initIdx + 1;
    //         $display("Initializing node %0d with distance %0d", initIdx, distance);
    //     end else begin
    //         initialized <= True;
    //         $display("BRAM initialization completed");
    //     end
    // endrule

    // rule handshake_macbridge;
    //     let resp_macbridge <- macbridge.pcieTxSrv.response.get;
    // endrule

    // rule handshake_cfgbridge;
    //     let resp_cfgbridge <- cfgbridge.chanTxSrv.response.get;
    // endrule

    // ==================== 发包规则 ====================
    rule send if(logFile != InvalidFile && cycleCount % (100*1000) == 0);
        let txReq = getEmptyMacEvent;
        txReq.srcMacId = sendingNodes;
        txReq.dstMacId = 0;
        txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        //txReq.mpduDigest.length = 2048;
        // txReq.rfParam.power = 60*32;//1920
        txReq.rfParam.power = 40*32;//1280
        txReq.mpduDigest.length = 1; //使长度变化，用于每次打印出不同的rxReq
        txReq.rfParam.mcs = 0;
        // macNodes[i].highMacTxSrv.request.put(txReq);
        // macbridge.pcieTxSrv.request.put(txReq);
        let bridgeTag = getEmptyBridgeTag();
        AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
            tData: zeroExtend(pack(tuple2(bridgeTag, txReq))),
            tKeep: '1,      // 所有字节有效
            tLast: True,     // 假设每个MAC事件对应一个AXI包
            tUser: 0
        };
        core.tx.put(axiPkt);
        $display("Sent packet from %d to %d", txReq.srcMacId, txReq.dstMacId);
        $fwrite(logFile, "[%8d ns] Sent packet from %0d to %0d\n",$time,  txReq.srcMacId, txReq.dstMacId);
    endrule

    rule receive;
        // let rxReq <- macNodes[0].highMacRxClt.request.get;
        // let rxReq <- macbridge.pcieRxClt.request.get;
        let rxpkt <- core.rx.get;
        MacEvent rxReq = unpack(truncate(rxpkt.tData));
        $display("Received packet from %d, the power is %d", rxReq.srcMacId, rxReq.rfParam.power);
        $fwrite(logFile,"[%8d ns] Received packet from %0d, the power is %0d\n", $time, rxReq.srcMacId, rxReq.rfParam.power);
        totalReceived <= totalReceived + 1;
    endrule

    rule logThroughput if((cycleCount % (1000*1000) == 0) && logFile != InvalidFile);
        let throughput = pack(totalReceived);
        // $fwrite(logFile, "%0d\n", throughput);
        $fwrite(logFile, "================================\n[%8d ns] sendingNodes: %0d, totalReceived: %0d\n================================\n", $time, sendingNodes, throughput);

        sendingNodes <= sendingNodes + 1; 
    endrule

    rule simEnd if(sendingNodes == fromInteger(valueOf(TEST_NODE_NUM)));
        $display("end");
        $finish();
    endrule

endmodule