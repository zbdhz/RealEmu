import GetPut::*;
import ClientServer::*;
import Types::*;
import PhyCore::*;

// 三个成功DATA填满输出FIFO；第三个已经结束但未交付时再请求ACK。
// 即时应答的RX抢占不能丢掉这个已经完成的成功事件。
module mkTestRxCompletionRetention(Empty);
    PhyCore phy <- mkPhyYansWifi(0);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(3)) received <- mkReg(0);
    Reg#(UInt#(3)) transmitted <- mkReg(0);
    Reg#(Bit#(3)) seen <- mkReg(0);
    rule tick; cycle <= cycle + 1; endrule
    rule sendData(cycle == 100 || cycle == 100 + fromInteger(250 * valueOf(US_CYCLES))
        || cycle == 100 + fromInteger(500 * valueOf(US_CYCLES)));
        let p = getEmptyPhyEvent;
        p.srcPhyId = 1; p.dstPhyId = 0;
        p.rfParam = RfParam{power: 1000, mcs: 7};
        p.ppduLen = 1064; p.mpduDigest.length = 1064;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        p.mpduDigest.cacheAddr = cycle == 100 ? 0
            : cycle == 100 + fromInteger(250 * valueOf(US_CYCLES)) ? 1 : 2;
        phy.phyRxSrv.request.put(p);
    endrule
    rule rxResponse; let ignored <- phy.phyRxSrv.response.get; endrule
    rule requestAck(cycle == fromInteger(700 * valueOf(US_CYCLES)));
        let p = getEmptyMacEvent;
        p.srcMacId = 0; p.dstMacId = 1;
        p.rfParam = RfParam{power: 1000, mcs: 0};
        p.mpduDigest.length = 14;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
        p.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_ACK));
        phy.lowMacTxSrv.request.put(p);
    endrule
    rule txResponse; let ignored <- phy.lowMacTxSrv.response.get; endrule
    rule channel;
        let p <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
        transmitted <= transmitted + 1;
    endrule
    rule receive(cycle >= fromInteger(750 * valueOf(US_CYCLES)));
        let p <- phy.lowMacRxClt.request.get;
        phy.lowMacRxClt.response.put(GenericResp{});
        Bit#(2) cookie = truncate(p.mpduDigest.cacheAddr);
        if (cookie >= 3 || seen[cookie] == 1) begin
            $display("TEST_FAIL rx_completion_retention duplicate/wrong DATA"); $finish(1);
        end
        seen <= seen | (1 << cookie); received <= received + 1;
    endrule
    rule finish(cycle == fromInteger(850 * valueOf(US_CYCLES)));
        if (received == 3 && seen == 7 && transmitted == 1)
            $display("TEST_PASS rx_completion_retention data=3 ack=1");
        else $display("TEST_FAIL rx_completion_retention data=%0d ack=%0d seen=%0d", received, transmitted, seen);
        $finish(0);
    endrule
endmodule
