import GetPut::*;
import ClientServer::*;
import FIFOF::*;
import Vector::*;
import Types::*;
import PhyCore::*;
import Arbitration::*;

// 5us的元数据传输延迟不应延长空口帧；RX_END应仍与源TX_END对齐。
module mkTestPhyAirTime(Empty);
    PhyCore tx <- mkPhyYansWifi(1);
    PhyCore rx <- mkPhyYansWifi(0);
    FIFOF#(PhyEvent) delayed <- mkFIFOF;
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) txEnd <- mkReg(0);
    Reg#(UInt#(32)) rxEnd <- mkReg(0);
    Reg#(UInt#(3)) received <- mkReg(0);
    rule tick; cycle <= cycle + 1; endrule
    rule observe;
        let a <- tx.getPhyStatus.get;
        let b <- rx.getPhyStatus.get;
        if (a.txEnd) txEnd <= cycle;
        if (b.rxEnd) rxEnd <= cycle;
    endrule
    rule send(cycle == 100);
        let p = getEmptyMacEvent;
        p.srcMacId = 1; p.dstMacId = 0;
        p.rfParam = RfParam{power: 1000, mcs: 7};
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        p.mpduDigest.length = 1064;
        tx.lowMacTxSrv.request.put(p);
    endrule
    rule accepted; let ignored <- tx.lowMacTxSrv.response.get; endrule
    rule channel;
        let p <- tx.phyTxClt.request.get;
        tx.phyTxClt.response.put(GenericResp{});
        delayed.enq(p);
    endrule
    rule releaseFrame(cycle >= 100 + fromInteger(5 * valueOf(US_CYCLES)));
        rx.phyRxSrv.request.put(delayed.first); delayed.deq;
    endrule
    rule acceptedRx; let ignored <- rx.phyRxSrv.response.get; endrule
    rule receive;
        let p <- rx.lowMacRxClt.request.get;
        rx.lowMacRxClt.response.put(GenericResp{});
        received <= received + 1;
    endrule
    rule finish(cycle == fromInteger(300 * valueOf(US_CYCLES)));
        if (received == 1 && txEnd != 0 && rxEnd >= txEnd && rxEnd - txEnd <= 2)
            $display("TEST_PASS phy_air_time tx_end=%0d rx_end=%0d metadata_delay_us=5", txEnd, rxEnd);
        else $display("TEST_FAIL phy_air_time tx_end=%0d rx_end=%0d received=%0d", txEnd, rxEnd, received);
        $finish(0);
    endrule
endmodule

`ifdef AIR_ARBITER_TEST
module mkTestArbiterAirOrder(Empty);
    ArbiterIFC arb <- mkArbiter;
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(3)) received <- mkReg(0);
    rule tick; cycle <= cycle + 1; endrule
    rule send(cycle == 10);
        let a = getEmptyPhyEvent;
        a.srcPhyId = 15; a.airTimeValid = True; a.airStarted = 101;
        let b = a; b.srcPhyId = 4; b.airStarted = 99;
        let c = a; c.srcPhyId = 1; c.airStarted = 100;
        arb.phyRxMetaSrv[15].request.put(a);
        arb.phyRxMetaSrv[4].request.put(b);
        arb.phyRxMetaSrv[1].request.put(c);
    endrule
    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        rule acknowledge; let ignored <- arb.phyRxMetaSrv[i].response.get; endrule
        rule receive;
            let p <- arb.phyTxMetaClt[i].request.get;
            arb.phyTxMetaClt[i].response.put(GenericResp{});
            if (i == 0) begin
                PhyId expected = received == 0 ? 4 : received == 1 ? 1 : 15;
                if (p.srcPhyId != expected || p.airStarted != 99 + zeroExtend(received)) begin
                    $display("TEST_FAIL arbiter_air_order index=%0d source=%0d time=%0d", received, p.srcPhyId, p.airStarted);
                    $finish(1);
                end
                received <= received + 1;
            end
        endrule
    end
    rule finish(cycle == 100);
        if (received == 3) $display("TEST_PASS arbiter_air_order 99 100 101");
        else $display("TEST_FAIL arbiter_air_order received=%0d", received);
        $finish(0);
    endrule
endmodule
`endif
