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
// import BsvTop::*;
import BsvTov_simple::*;

typedef 16 TEST_NODE_NUM;
typedef 1000 Send_Delta_Time;
typedef 500  Send_Pkt_Num;
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


module mkTestRawEmuCore_collision(Empty);
    let core <- mkEmuCore;
    // 初始化索引
    Reg#(UInt#(32)) initIdx <- mkReg(0);
    // 初始化完成标志
    Reg#(Bool) initialized <- mkReg(True);
    // ==================== 控制寄存器 ====================
    Reg#(UInt#(64)) cycleCount <- mkReg(3);
    Reg#(MacId) sendingNodes <- mkReg(0);     // 总发送包数
    Reg#(UInt#(64)) totalReceived <- mkReg(0);     // 总接收包数
    Reg#(UInt#(64)) receivedFrom1 <- mkReg(0);     
    Reg#(UInt#(64)) receivedFrom2 <- mkReg(0);     
    Reg#(File) logFile <- mkReg(InvalidFile);     // 日志文件句柄

    rule initialize (cycleCount == 10);
        let fd <- $fopen("/home/emu/dev/RealEmu/scripts/collison.txt", "w");
        logFile <= fd;
    endrule

    // ==================== 时钟计数 ====================
    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    // ==================== 发包规则 ====================//原生包发送（任务）
    rule send1 if(initialized && logFile != InvalidFile && (cycleCount % (fromInteger(valueOf(Send_Delta_Time))*200) == 0)||(cycleCount % (fromInteger(valueOf(Send_Delta_Time))*200) == 0));
        let txReq = getEmptyMacEvent;
        txReq.srcMacId = 1;
        txReq.dstMacId = 0;
        txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        //txReq.mpduDigest.length = 2048;
        txReq.rfParam.power = 32*10 + 578;//320有效
        txReq.mpduDigest.length = 1457; //使长度变化，用于每次打印出不同的rxReq
        txReq.rfParam.mcs = 0;
        // txReq.mpduDigest.duration = 2164;
        // txReq.mpduDigest.duration = 0;
        let bridgeTag = getEmptyBridgeTag();
        AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
            tData: zeroExtend(pack(tuple2(txReq,bridgeTag))),
            tKeep: '1,      // 所有字节有效
            tLast: True,     // 假设每个MAC事件对应一个AXI包
            tUser: 0
        };
        core.tx.put(axiPkt);
        sendingNodes <= sendingNodes + 1;
        $display("Sent packet from %d to %d", txReq.srcMacId, txReq.dstMacId);
        $fwrite(logFile, "[%8d ns] Sent packet from %0d to %0d, cycleCount:%0d\n",$time,  txReq.srcMacId, txReq.dstMacId, cycleCount);
    endrule

    // ==================== 发包规则 ====================//干扰包发送（任务）
    rule send2 if(initialized && logFile != InvalidFile && cycleCount % (fromInteger(valueOf(Send_Delta_Time))*200)== 5*200);
        let txReq = getEmptyMacEvent;
        txReq.srcMacId = 2;
        txReq.dstMacId = 0;
        txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        //txReq.mpduDigest.length = 2048;
        txReq.rfParam.power = 32*10 +578;//320有效
        txReq.mpduDigest.length = 1457; //使长度变化，用于每次打印出不同的rxReq
        txReq.rfParam.mcs = 0;
        // txReq.mpduDigest.duration = 0;
        // txReq.mpduDigest.duration = 2164;
        let bridgeTag = getEmptyBridgeTag();
        AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
            tData: zeroExtend(pack(tuple2(txReq,bridgeTag))),
            tKeep: '1,      // 所有字节有效
            tLast: True,     // 假设每个MAC事件对应一个AXI包
            tUser: 0
        };
        // core.tx.put(axiPkt);
        $display("Sent packet from %d to %d", txReq.srcMacId, txReq.dstMacId);
        $fwrite(logFile, "[%8d ns] Sent packet from %0d to %0d, cycleCount:%0d\n",$time,  txReq.srcMacId, txReq.dstMacId, cycleCount);
    endrule


    rule receive;
        let rxpkt <- core.rx.get;
        MacEvent rxReq = unpack(truncate(rxpkt.tData));
        $display("Received packet from %d, the power is %d", rxReq.srcMacId, rxReq.rfParam.power);
        $fwrite(logFile,"[%8d ns] Received packet from %0d, the power is %0d, cycleCount:%0d\n", $time, rxReq.srcMacId, rxReq.rfParam.power, cycleCount);
        if(rxReq.srcMacId == 1)begin
            receivedFrom1 <= receivedFrom1 + 1;
        end
        if(rxReq.srcMacId == 2)begin
            receivedFrom2 <= receivedFrom2 + 1;
        end


        totalReceived <= totalReceived + 1;
    endrule

    // rule logThroughput if(initialized && (cycleCount % (1000*1000) == 0) && logFile != InvalidFile);
    //     let throughput = pack(totalReceived);
    //     // $fwrite(logFile, "%0d\n", throughput);
    //     $fwrite(logFile, "================================\n[%8d ns] sendingNodes: %0d, totalReceived: %0d\n================================\n", $time, sendingNodes, throughput);

    //     // sendingNodes <= sendingNodes + 1; 
    // endrule

    rule simEnd if( sendingNodes == fromInteger(valueOf(Send_Pkt_Num)) + 1);
        $fwrite(logFile, "Node1send_Num: %0d, Node1Received_Num: %0d, Node2Received_Num: %0d\n", sendingNodes-1, receivedFrom1, receivedFrom2);
        $display("end");
        $finish();
    endrule

endmodule