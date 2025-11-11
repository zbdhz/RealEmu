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

// typedef 8 NODE_NUM;

module mkTestTop(Empty);
    // ==================== 节点实例化 ====================
        Vector#(NODE_NUM, MacCore) macNodes <- genWithM(compose(mkMacDCF, fromInteger));
        Vector#(NODE_NUM, PhyCore) phyNodes <- genWithM(compose(mkPhyYansWifi, fromInteger));
        Vector#(NODE_NUM, GainLossModel) channels <- replicateM(mkGainLossModelIdeal);
        ArbiterIFC pollController <- mkArbiter;

        Reg#(UInt#(10)) sendingNodes <- mkReg(1);     // 总接收包数
        // ==================== 控制寄存器 ====================
        Reg#(UInt#(64)) cycleCount <- mkReg(3);
        Reg#(UInt#(64)) totalReceived <- mkReg(0);     // 总接收包数
        Reg#(File) logFile <- mkReg(InvalidFile);     // 日志文件句柄

        // ==================== 初始化 ====================
        rule initialize (cycleCount == 10);
            let fd <- $fopen("/home/emu/dev/RealEmu/scripts/throughout.txt", "w");
            logFile <= fd;
        endrule

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

        for (UInt#(10) i = 1; i < fromInteger(valueOf(NODE_NUM)); i = i + 1)begin
            rule send if(i<=sendingNodes);
                let txReq = getEmptyMacEvent;
                txReq.srcMacId = unpack(pack(i));
                txReq.dstMacId = 0;
                txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
                //txReq.mpduDigest.length = 2048;
                txReq.rfParam.power = 60*32;
                txReq.mpduDigest.length = 2048; //使长度变化，用于每次打印出不同的rxReq
                txReq.rfParam.mcs = 7;
                macNodes[i].highMacTxSrv.request.put(txReq);
            endrule
        end

        rule receive;
            let rxReq <- macNodes[0].highMacRxClt.request.get;
            totalReceived <= totalReceived + 1;
        endrule

        rule logThroughput if((cycleCount % (1000*1000) == 0) && logFile != InvalidFile);
            let throughput = pack(totalReceived);
            $fwrite(logFile, "%0d\n", throughput);
            sendingNodes <= sendingNodes + 1; 
        endrule

        rule simEnd if(sendingNodes == fromInteger(valueOf(NODE_NUM)));
            $display("end");
            $finish();
        endrule

endmodule
