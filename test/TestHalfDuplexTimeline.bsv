import GetPut::*;
import ClientServer::*;
import Types::*;
import PhyCore::*;

// 元数据晚到不能让接收机补收本机TX期间开始的前导；恰在TX_END开始则可接收。
module mkTestHalfDuplexTimeline(Empty);
    PhyCore phy <- mkPhyYansWifi(0);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) ownEnd <- mkReg(0);
    Reg#(Bool) pending <- mkReg(False);
    Reg#(Bool) second <- mkReg(False);
    Reg#(UInt#(3)) received <- mkReg(0);
    Reg#(Bool) correctCookie <- mkReg(True);
    rule tick; cycle <= cycle + 1; endrule
    rule sendSelf(cycle == 100 || cycle == 100 + fromInteger(600 * valueOf(US_CYCLES)));
        let p = getEmptyMacEvent;
        p.srcMacId = 0; p.dstMacId = 1;
        p.rfParam = RfParam{power: 1000, mcs: 7};
        p.mpduDigest.length = 14;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        p.mpduDigest.cacheAddr = cycle == 100 ? 0 : 1;
        phy.lowMacTxSrv.request.put(p);
    endrule
    rule txResponse; let ignored <- phy.lowMacTxSrv.response.get; endrule
    rule channel;
        let p <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
        ownEnd <= p.airStarted + fromInteger(24 * valueOf(US_CYCLES));
        second <= p.mpduDigest.cacheAddr == 1; pending <= True;
    endrule
    rule delayedIncoming(pending && cycle == ownEnd + 5);
        let p = getEmptyPhyEvent;
        p.srcPhyId = 1; p.dstPhyId = 0;
        p.rfParam = RfParam{power: 1000, mcs: 7};
        p.ppduLen = 1064; p.mpduDigest.length = 1064;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        p.mpduDigest.cacheAddr = second ? 1 : 0;
        p.airTimeValid = True;
        p.airStarted = ownEnd - (second ? 0 : 1);
        phy.phyRxSrv.request.put(p); pending <= False;
    endrule
    rule rxResponse; let ignored <- phy.phyRxSrv.response.get; endrule
    rule receive;
        let p <- phy.lowMacRxClt.request.get;
        phy.lowMacRxClt.response.put(GenericResp{});
        received <= received + 1;
        correctCookie <= correctCookie && p.mpduDigest.cacheAddr == 1;
    endrule
    rule finish(cycle == fromInteger(1000 * valueOf(US_CYCLES)));
        if (received == 1 && correctCookie)
            $display("TEST_PASS half_duplex_timeline during_tx_rejected exact_end_received");
        else $display("TEST_FAIL half_duplex_timeline received=%0d correct=%0d", received, correctCookie);
        $finish(0);
    endrule
endmodule
