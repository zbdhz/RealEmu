import GetPut::*;
import Connectable::*;
import ClientServer::*;

import Types::*;
import PhyCore::*;
// 最简单的一次发包情况

typedef 2000 Send_delta_time_us;
typedef 20 Send_Num;

module mkTestPhy(Empty);

    Reg#(Bool) isInitReg <- mkReg(False);

    PhyCore dut0 <- mkPhyYansWifi(0);
    PhyCore dut1 <- mkPhyYansWifi(1);

    mkConnection(dut0.phyTxClt, dut1.phyRxSrv);  // dut0发送 -> dut1接收
    mkConnection(dut1.phyTxClt, dut0.phyRxSrv);  // dut1发送 -> dut0接收

    Reg#(UInt#(64)) cycleCount <- mkReg(0);
    Reg#(UInt#(12)) cntCount <- mkReg(0);

    rule updateclock;
            cycleCount <= cycleCount + 1;
    endrule


    rule handshake0;
        let resp <- dut0.lowMacTxSrv.response.get;
    endrule
    
    // rule handshake1;
    //     let resp <- dut0.phyRxSrv.response.get;
    // endrule

    rule send if (cycleCount % (fromInteger(valueOf(Send_delta_time_us))*200) == 0);
        let cnt = cntCount;
        cntCount <= cntCount + 1;
        let txReq = getEmptyMacEvent;
        txReq.srcMacId = 0;
        txReq.dstMacId = 1;
        txReq.rfParam.power = 20*32;
        txReq.rfParam.mcs = 0;
        txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        txReq.mpduDigest.length = 1000;
        dut0.lowMacTxSrv.request.put(txReq);
        $display("packet send%d",cnt);
    endrule

    rule receive;
        let rxReq <- dut1.lowMacRxClt.request.get;
        $display("packet receive");
    endrule

    rule simEnd(cntCount == fromInteger(valueOf(Send_Num)));
        $display("Test Pass");
        $finish();
    endrule

    // //power过低不会被感应到
    // rule send1 if (cycleCount == 100);
    //     let txReq = getEmptyMacEvent;
    //     txReq.srcMacId = 0;
    //     txReq.dstMacId = 1;
    //     txReq.rfParam.power = -40*32;
    //     txReq.rfParam.mcs = 7;
    //     txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
    //     txReq.mpduDigest.length = 1024;
    //     dut0.lowMacTxSrv.request.put(txReq);
    //     $display("packt1");
    // endrule

    // //该包被感应到使得phy状态改变
    // rule send2 if (cycleCount == 200);
    //     let txReq = getEmptyMacEvent;
    //     txReq.srcMacId = 0;
    //     txReq.dstMacId = 1;
    //     txReq.rfParam.power = 31*32;
    //     txReq.rfParam.mcs = 7;
    //     txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
    //     txReq.mpduDigest.length = 1024;
    //     dut0.lowMacTxSrv.request.put(txReq);
    //     $display("packt2");
    // endrule

    // //该包将被视为干扰，干扰SYNC状态
    // rule send3 if (cycleCount == 300);
    //     let txReq = getEmptyMacEvent;
    //     txReq.srcMacId = 0;
    //     txReq.dstMacId = 1;
    //     txReq.rfParam.power = 10*32;
    //     txReq.rfParam.mcs = 7;
    //     txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
    //     txReq.mpduDigest.length = 1024;
    //     dut0.lowMacTxSrv.request.put(txReq);
    //     $display("packt3");
    // endrule

    // //该包将被视为干扰，干扰RX状态
    // rule send4 if (cycleCount == 5000);
    //     let txReq = getEmptyMacEvent;
    //     txReq.srcMacId = 0;
    //     txReq.dstMacId = 1;
    //     txReq.rfParam.power = 10*32;
    //     txReq.rfParam.mcs = 7;
    //     txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
    //     txReq.mpduDigest.length = 1024;
    //     dut0.lowMacTxSrv.request.put(txReq);
    //     $display("packt4");
    // endrule

    // rule receive;
    //     let rxReq <- dut1.lowMacRxClt.request.get;
    // endrule

    // rule simEnd(cycleCount == 100_0_000);//1ms
    //     $display("Test Pass");
    //     $finish();
    // endrule

endmodule