import GetPut::*;
import Connectable::*;
import ClientServer::*;
import Vector::*;
import StmtFSM::*;
import FIFO::*;

import Types::*;
import MacCore::*;
import CsmaUtils::*;
import PrimUtils::*;
import PhyCoreSim::*;
import Channel::*;
import Arbitration::*;

typedef 9 TEST_NODE_NUM;
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

module mkTestTop(Empty);
    // ==================== 节点实例化 ====================
        Vector#(NODE_NUM, MacCore) macNodes <- genWithM(compose(mkMacDCF, fromInteger));
        Vector#(NODE_NUM, PhyCore) phyNodes <- genWithM(compose(mkPhyYansWifi, fromInteger));
        // Vector#(NODE_NUM, GainLossModel) channels <- replicateM(mkGainLossModelIdeal);
        Vector#(NODE_NUM, GainLossModel) channels;
        for(Integer i=0; i<valueOf(NODE_NUM); i=i+1) begin
            let fname = "bram_" + intToString(i) + ".txt";
            channels[i] <- mkGainLossModelLogDistance(fname);
        end

        ArbiterIFC pollController <- mkArbiter;

        Reg#(UInt#(10)) sendingNodes <- mkReg(1);     // 总接收包数
        // ==================== 控制寄存器 ====================
        Reg#(UInt#(64)) cycleCount <- mkReg(3);
        Reg#(UInt#(64)) totalReceived <- mkReg(0);     // 总接收包数
        Reg#(File) logFile <- mkReg(InvalidFile);     // 日志文件句柄

        // ==================== 初始化 ====================
        // rule printFilenamesOnce (cycleCount == 5);
        //     for(Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        //         $display("Opening file: bram_%0d.txt", i);
        //     end
        // endrule

        rule initialize (cycleCount == 10);
            let fd <- $fopen("/home/emu/dev/RealEmu/scripts/throughout.txt", "w");
            logFile <= fd;
        endrule
        // ==================== 时钟计数 ====================
        rule updateclock;
            cycleCount <= cycleCount + 1;
        endrule

        // ==================== 节点连接 ====================
        for(Integer i=0; i<valueOf(NODE_NUM); i=i+1) begin
            mkConnection(macNodes[i].lowMacTxClt, phyNodes[i].lowMacTxSrv);
            mkConnection(macNodes[i].lowMacRxSrv, phyNodes[i].lowMacRxClt);
            mkConnection(phyNodes[i].phyTxClt, channels[i].phyTxSrv);
            mkConnection(phyNodes[i].phyRxSrv, channels[i].phyRxClt);
            mkConnection(pollController.phyTxMetaClt[i], channels[i].phyRxMetaSrv);
            mkConnection(pollController.phyRxMetaSrv[i], channels[i].phyTxMetaClt);
        end
      
        rule updatePhyStatus;
            for (Integer i = 0; i < valueof(NODE_NUM); i = i + 1) begin
                let phyStatus = phyNodes[i].getPhyStatus;
                macNodes[i].phyStatus.put(phyStatus);
            end
        endrule

        for(Integer i=0; i<valueOf(NODE_NUM); i=i+1) begin
            rule handshake;
                let resp <- macNodes[i].highMacTxSrv.response.get;
            endrule
        end
        // ==================== 发包规则 ====================
        for (UInt#(10) i = 1; i < fromInteger(valueOf(TEST_NODE_NUM)); i = i + 1)begin
            rule send if(i<=sendingNodes && logFile != InvalidFile);
                let txReq = getEmptyMacEvent;
                txReq.srcMacId = unpack(pack(i));
                txReq.dstMacId = 0;
                txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
                //txReq.mpduDigest.length = 2048;
                txReq.rfParam.power = 60*32;//1920
                txReq.mpduDigest.length = 2048; //使长度变化，用于每次打印出不同的rxReq
                txReq.rfParam.mcs = 7;
                macNodes[i].highMacTxSrv.request.put(txReq);
                $display("Sent packet from %d to %d", txReq.srcMacId, txReq.dstMacId);
                $fwrite(logFile, "[%8d ns] Sent packet from %0d to %0d\n",$time,  txReq.srcMacId, txReq.dstMacId);
            endrule
        end

        rule receive;
            let rxReq <- macNodes[0].highMacRxClt.request.get;
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
