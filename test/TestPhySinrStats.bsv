import GetPut::*;
import Connectable::*;
import ClientServer::*;
import Vector::*;

import Types::*;
import PhyCore::*;

// 配置参数
typedef 1 NUM_SINR;
typedef 1000 PKTS_PER_SINR;
typedef 4 SINR_STEP; // 每步0.125dB（4/32 = 0.125dB）
typedef 0 MCS;
typedef 15000 Send_delta_time;
typedef 1000 Send_time;
typedef 12000 Print_time;

function Int#(12) getSinrStart();
    return 10*32;
endfunction

module mkTestPhySinrStats(Empty);

    // 统计寄存器：用 replicateM(mkReg(0)) 初始化为 0，避免写冲突
    Vector#(NUM_SINR, Reg#(UInt#(16))) pktSent <- replicateM(mkReg(0));
    Vector#(NUM_SINR, Reg#(UInt#(16))) pktRecv <- replicateM(mkReg(0));

    // 当前测试点
    Reg#(UInt#(8)) sinrIdx <- mkReg(0);
    Reg#(UInt#(16)) pktIdx <- mkReg(0);

    // 发射/接收节点
    PhyCore dut0 <- mkPhyYansWifi(0);
    PhyCore dut1 <- mkPhyYansWifi(1);

    mkConnection(dut0.phyTxClt, dut1.phyRxSrv);
    mkConnection(dut1.phyTxClt, dut0.phyRxSrv);

    Reg#(UInt#(64)) cycleCount <- mkReg(0);

    // 发送数据包
    rule sendPkt if (cycleCount % fromInteger(valueOf(Send_delta_time)) == fromInteger(valueOf(Send_time)) && pktIdx < fromInteger(valueOf(PKTS_PER_SINR)) && sinrIdx < fromInteger(valueOf(NUM_SINR)));
        let txReq = getEmptyMacEvent;
        txReq.srcMacId = 0;
        txReq.dstMacId = 1;

        let sinrOffset = zeroExtend(sinrIdx) * fromInteger(valueOf(SINR_STEP));
        let sinrPower = getSinrStart() + unpack(pack(sinrOffset));
        txReq.rfParam.power = sinrPower;

        txReq.rfParam.mcs = fromInteger(valueOf(MCS));
        txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        txReq.mpduDigest.length = 1;

        dut0.lowMacTxSrv.request.put(txReq);
        $display("Send pkt id:%d", pktIdx+1);
        pktSent[sinrIdx] <= pktSent[sinrIdx] + 1;
        pktIdx <= pktIdx + 1;
    endrule

    // 接收统计
    rule countRecv;
        let rxReq <- dut1.lowMacRxClt.request.get;
        $display("Recv pkt");
        if (sinrIdx < fromInteger(valueOf(NUM_SINR))) begin
            pktRecv[sinrIdx] <= pktRecv[sinrIdx] + 1;
        end
    endrule

    // 切换到下一个 SINR 点
    rule nextSinr if ( cycleCount % fromInteger(valueOf(Send_delta_time)) == fromInteger(valueOf(Print_time)) - 1 && pktIdx == fromInteger(valueOf(PKTS_PER_SINR)) && sinrIdx < fromInteger(valueOf(NUM_SINR)));
        sinrIdx <= sinrIdx + 1;
        pktIdx <= 0;
        $display("sinrIdx: %0d ", sinrIdx);
    endrule

    // 输出统计信息
    rule printStats (cycleCount % fromInteger(valueOf(Send_delta_time)) == fromInteger(valueOf(Print_time)) && sinrIdx == fromInteger(valueOf(NUM_SINR)));
        // $display("==== SINR 丢包率统计 ====");
        $display("==== SINR loss Test ====");
        for (Integer i = 0; i < valueOf(NUM_SINR); i = i + 1) begin
            let sinr_db = (getSinrStart() + fromInteger(i) * fromInteger(valueOf(SINR_STEP)));
            let sent = pktSent[i];
            let recv = pktRecv[i];
            // let loss = sent > 0 ? (sent - recv) * 1000 / sent : 0;
            // $display("SINR: %0d dB, 发送: %0d, 接收: %0d, 丢包率: %0d ‱", sinr_db, sent, recv, loss);
        $display("SINR: %0d /32dB, send: %0d, Recv: %0d", sinr_db, sent, recv);
            end
        $display("==== pass! ====");
        $finish();
    endrule

    // 模拟周期推进
    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    // 响应读取
    rule handshake0;
        let resp <- dut0.lowMacTxSrv.response.get;
    endrule

endmodule
