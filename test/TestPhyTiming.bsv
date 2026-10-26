import GetPut::*;
import ClientServer::*;
import StmtFSM::*;
import Types::*;
import PhyCore::*;

// Golden airtimes below are independent, precomputed IEEE 802.11a values.
function UInt#(32) expectedUs(UInt#(4) id);
    case (id)
        0: return 2024; // 1500 B @ 6 M
        1: return 1440; 2: return 968; 3: return 732; 4: return 496;
        5: return 376; 6: return 260; 7: return 200; 8: return 180;
        9: return 9732; // 65535 B @ 54 M: catches the old 10-bit quotient truncation.
        default: return 24; // 14 B @ 54 M
    endcase
endfunction

module mkTestPhyTiming(Empty);
    PhyCore phy <- mkPhyYansWifi(1);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) txStart <- mkReg(0);
    Reg#(UInt#(32)) rxInjected <- mkReg(0);
    Reg#(UInt#(32)) longRxInjected <- mkReg(0);
    Reg#(UInt#(4)) txEnded <- mkReg(0);
    Reg#(UInt#(4)) txStarted <- mkReg(0);
    Reg#(UInt#(4)) txAccepted <- mkReg(0);
    Reg#(UInt#(4)) txForwarded <- mkReg(0);
    Reg#(UInt#(4)) activeId <- mkReg(0);
    Reg#(UInt#(3)) received <- mkReg(0);
    Reg#(UInt#(4)) testIndex <- mkReg(0);
    Reg#(PhyFsmState) previous <- mkReg(PHY_IDLE);
    Reg#(Bool) cca <- mkReg(False);
    rule tick;
        cycle <= cycle + 1;
    endrule
    rule observe;
        let s <- phy.getPhyStatus.get;
        previous <= s.state;
        cca <= s.cca;
        if (s.state == PHY_TX && previous != PHY_TX) begin
            txStart <= cycle;
            txStarted <= txStarted + 1;
        end
        if (s.txEnd) begin
            UInt#(32) expected = expectedUs(activeId) * fromInteger(valueOf(US_CYCLES));
            if (cycle - txStart != expected) begin
                $display("TEST_FAIL TX duration id=%0d got=%0d expected=%0d", activeId, cycle - txStart, expected);
                $finish(1);
            end
            $display("TIMING_PASS id=%0d cycles=%0d model_us=%0d", activeId, expected, expectedUs(activeId));
            txEnded <= txEnded + 1;
        end
        if (s.rxEnd && cycle - rxInjected != fromInteger(180 * valueOf(US_CYCLES) + 1)) begin
            $display("TEST_FAIL RX duration got=%0d", cycle - rxInjected);
            $finish(1);
        end
    endrule
    rule channel;
        let packet <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
        activeId <= unpack(truncate(packet.mpduDigest.cacheAddr));
        if (packet.mpduDigest.cacheAddr != zeroExtend(pack(txForwarded))) begin
            $display("TEST_FAIL reordered TX timing tag"); $finish(1);
        end
        txForwarded <= txForwarded + 1;
    endrule
    rule accepted;
        let response <- phy.lowMacTxSrv.response.get;
        txAccepted <= txAccepted + 1;
    endrule
    rule rxResponse;
        let response <- phy.phyRxSrv.response.get;
    endrule
    rule receive;
        let packet <- phy.lowMacRxClt.request.get;
        phy.lowMacRxClt.response.put(GenericResp{});
        received <= received + 1;
    endrule
    function MacEvent tx(UInt#(4) id, Bit#(16) len, Mcs rate);
        let packet = getEmptyMacEvent;
        packet.srcMacId = 1; packet.dstMacId = 0;
        packet.rfParam = RfParam{power: 1000, mcs: rate};
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = len;
        packet.mpduDigest.cacheAddr = zeroExtend(pack(id));
        return packet;
    endfunction
    function PhyEvent rx(Bit#(16) len, Mcs rate, PowerDb power);
        let packet = getEmptyPhyEvent;
        packet.srcPhyId = 2; packet.dstPhyId = 3;
        packet.rfParam = RfParam{power: power, mcs: rate};
        packet.ppduLen = len;
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = len;
        return packet;
    endfunction
    Stmt test = seq
        delay(100);
        action phy.phyRxSrv.request.put(rx(1062, 7, 1000)); rxInjected <= cycle; endaction
        delay(1);
        phy.lowMacTxSrv.request.put(tx(0, 1500, 0)); // Waits for the actual incoming RX to finish.
        await(txStarted == 1);
        phy.phyRxSrv.request.put(rx(14, 7, 74)); // Weak RX cannot change TX duration or extend CCA.
        await(txEnded == 1);
        for (testIndex <= 0; testIndex < 8; testIndex <= testIndex + 1) seq
            phy.lowMacTxSrv.request.put(tx(testIndex + 1, 1062, truncate(pack(testIndex))));
            await(txEnded == testIndex + 2);
        endseq
        phy.lowMacTxSrv.request.put(tx(9, 65535, 7));
        await(txEnded == 10);
        action
            // Both requests arrive in the same cycle. The long strong RX is
            // ignored for decoding during TX, but its own duration must reach CCA.
            phy.lowMacTxSrv.request.put(tx(10, 14, 7));
            phy.phyRxSrv.request.put(rx(1500, 0, 1000));
            longRxInjected <= cycle;
        endaction
        await(txEnded == 11);
        delay(fromInteger(valueOf(US_CYCLES)));
        action
            if (!cca) begin $display("TEST_FAIL lost simultaneous RX duration/CCA"); $finish(1); end
        endaction
        await(cycle >= longRxInjected + fromInteger(2024 * valueOf(US_CYCLES) + 5));
        action
            if (cca || received != 1 || txStarted != 11 || txForwarded != 11 || txAccepted != 11) begin
                $display("TEST_FAIL timing drain cca=%0d rx=%0d tx=%0d/%0d/%0d", cca, received, txStarted, txForwarded, txAccepted);
                $finish(1);
            end
            $display("TEST_PASS phy_timing tagged_TX_RX_and_airtime");
            $finish(0);
        endaction
    endseq;
    mkAutoFSM(test);
    rule watchdog(cycle == fromInteger(25000 * valueOf(US_CYCLES)));
        $display("TEST_FAIL phy_timing watchdog"); $finish(1);
    endrule
endmodule
