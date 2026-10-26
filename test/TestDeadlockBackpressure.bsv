import GetPut::*;
import ClientServer::*;
import Connectable::*;
import FIFOF::*;
import DReg::*;
import Types::*;
import MacCore::*;
import CsmaUtils::*;
import PhyCore::*;

// D03: blocked TX must not consume the one opportunity to send the next ACK.
// Only the external PHY status is stubbed; the production MAC/backoff FSM is used.
module mkTestMacBackpressure(Empty);
    MacCore mac <- mkMacDCF(1);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(4)) submitted <- mkReg(0);
    Reg#(UInt#(4)) replies <- mkReg(0);
    Reg#(UInt#(4)) delivered <- mkReg(0);
    Reg#(Bit#(32)) dcf <- mkReg('1);
    Reg#(Bool) txEnded <- mkDReg(False);

    rule tick;
        cycle <= cycle + 1;
    endrule
    // Keep the clock counter independent of the DUT combinational interface.
    rule status;
        let s = getEmptyPhyStatus;
        s.txEnd = txEnded;
        mac.phyStatus.put(s);
    endrule
    rule inject(submitted < 3 && cycle >= 100 + zeroExtend(submitted) * 6000);
        let packet = getEmptyMacEvent;
        packet.srcMacId = 0;
        packet.dstMacId = 1;
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = 1062;
        packet.mpduDigest.cacheAddr = zeroExtend(pack(submitted));
        mac.lowMacRxSrv.request.put(packet);
        submitted <= submitted + 1;
    endrule
    rule receiveResponse;
        let response <- mac.lowMacRxSrv.response.get;
    endrule
    rule receiveData;
        let packet <- mac.highMacRxClt.request.get;
        mac.highMacRxClt.response.put(GenericResp{});
        delivered <= delivered + 1;
    endrule
    // Originally two ACKs filled TX FIFO and the third lost DONE. With D02 the
    // first outstanding TX also blocks its successor; release must recover both.
    rule releaseTx(cycle >= 30000);
        let packet <- mac.lowMacTxClt.request.get;
        mac.lowMacTxClt.response.put(GenericResp{});
        txEnded <= True; // External PHY stub completes each accepted ACK next cycle.
        if (!isAckFrame(packet.mpduDigest)) begin
            $display("TEST_FAIL mac_backpressure: expected ACK");
            $finish(1);
        end
        replies <= replies + 1;
        $display("TRACE cycle=%0d ACK_OUT id=%0d", cycle, packet.mpduDigest.cacheAddr);
    endrule
    rule query(cycle == 49000);
        mac.macRegSrv.request.put(RegAccessReq{
            writeEnable: False, regOffset: mac_dcf_state_off, writeData: 0});
    endrule
    rule queryResponse;
        let response <- mac.macRegSrv.response.get;
        dcf <= response.readData;
    endrule
    rule finish(cycle == 50000);
        $display("RESULT submitted=%0d delivered=%0d replies=%0d dcf=%0d",
                 submitted, delivered, replies, dcf);
        if (submitted == 3 && delivered == 3 && replies == 3 && dcf == 0) begin
            $display("TEST_PASS mac_backpressure");
            $finish(0);
        end
        else begin
            $display("TEST_FAIL mac_backpressure: full FIFO lost DONE");
            $finish(1);
        end
    endrule
endmodule

// D02: a control TX held by channel backpressure must not supply TX_END for
// the next RTS. Real MAC + PHY are used; incoming DATA completions are injected
// through the normal MAC RX request interface to request three ACKs.
module mkTestMacPhyTxOrder(Empty);
    MacCore mac <- mkMacDCF(1);
    PhyCore phy <- mkPhyYansWifi(1);
    mkConnection(mac.lowMacTxClt, phy.lowMacTxSrv);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(3)) injected <- mkReg(0);
    Reg#(UInt#(5)) forwarded <- mkReg(0);
    Reg#(UInt#(5)) started <- mkReg(0);
    Reg#(UInt#(5)) ended <- mkReg(0);
    Reg#(UInt#(3)) delivered <- mkReg(0);
    Reg#(PhyFsmState) previous <- mkReg(PHY_IDLE);
    Reg#(Bit#(4)) activeSubtype <- mkReg(0);
    Reg#(Bit#(32)) fifo <- mkReg('1);
    rule tick;
        cycle <= cycle + 1;
    endrule
    rule status;
        let s <- phy.getPhyStatus.get;
        mac.phyStatus.put(s);
        previous <= s.state;
        if (s.state == PHY_TX && previous != PHY_TX) started <= started + 1;
        if (s.txEnd) begin
            ended <= ended + 1;
            $display("TRACE cycle=%0d TX_END subtype=%0d", cycle, activeSubtype);
        end
    endrule
    rule configure(cycle == 1);
        mac.macRegSrv.request.put(RegAccessReq{
            writeEnable: True, regOffset: mac_rts_thresh_off,
`ifdef ORDER_DATA
            writeData: 65535});
`else
            writeData: 100});
`endif
    endrule
`ifdef ORDER_DATA
    // A short response timeout exposes accidental arming by the preceding ACK:
    // all seven DATA attempts must still actually transmit, rather than losing
    // the first attempt to the legacy CTS-timeout check before DATA is sent.
    rule configureShortTimeout(cycle == 2);
        mac.macRegSrv.request.put(RegAccessReq{
            writeEnable: True, regOffset: mac_timeout_off, writeData: 1});
    endrule
`endif
    rule inject(injected < 3 && cycle >= 100 + zeroExtend(injected) * 20000);
        let packet = getEmptyMacEvent;
        packet.srcMacId = 0;
        packet.dstMacId = 1;
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = 1062;
        packet.mpduDigest.cacheAddr = zeroExtend(pack(injected));
        mac.lowMacRxSrv.request.put(packet);
        injected <= injected + 1;
    endrule
    rule receivedInput;
        let response <- mac.lowMacRxSrv.response.get;
    endrule
    rule receive;
        let packet <- mac.highMacRxClt.request.get;
        mac.highMacRxClt.response.put(GenericResp{});
        delivered <= delivered + 1;
    endrule
    rule enqueue(cycle == 70000);
        let packet = getEmptyMacEvent;
        packet.srcMacId = 1;
        packet.dstMacId = 0;
        packet.rfParam = RfParam{power: 1000, mcs: 7};
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = 1062;
        mac.highMacTxSrv.request.put(packet);
    endrule
    rule channel(cycle >= 150000);
        let packet <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
        activeSubtype <= packet.mpduDigest.frameSubType;
        forwarded <= forwarded + 1;
        $display("TRACE cycle=%0d CHANNEL_OUT subtype=%0d", cycle, packet.mpduDigest.frameSubType);
    endrule
    rule query(cycle == 1990000);
        mac.macRegSrv.request.put(RegAccessReq{
            writeEnable: False, regOffset: mac_fifoin_count_off, writeData: 0});
    endrule
    rule queryResponse;
        let response <- mac.macRegSrv.response.get;
        if (cycle > 1990000) fifo <= response.readData;
    endrule
    rule finish(cycle == 2000000);
        $display("RESULT delivered=%0d forwarded=%0d started=%0d ended=%0d fifo=%0d",
                 delivered, forwarded, started, ended, fifo);
        if (delivered == 3 && forwarded == 10 && started == 10 && ended == 10 && fifo == 0) begin
            $display("TEST_PASS mac_phy_tx_order");
            $finish(0);
        end
        else begin
            $display("TEST_FAIL mac_phy_tx_order");
            $finish(1);
        end
    endrule
endmodule

// D03: hold DONE behind an implicitly guarded FIFO enq, then cancel and restart.
module mkTestCsmaDoneHandshake(Empty);
    Wire#(PhyStatus) status <- mkDWire(getEmptyPhyStatus);
    TimeGen us <- mkUsGen(1); // Standalone MAC timing test: one test cycle per us.
    Reg#(MacConfig) cfg <- mkReg(getDefaultMacCfg);
    TimeGen slot <- mkSlotGen(us, cfg);
    let backoff <- mkCsmaCaBackOff(status, us, slot, 1);
    FIFOF#(Bool) blocked <- mkSizedFIFOF(1);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(3)) consumed <- mkReg(0);
    Reg#(Bool) held <- mkReg(False);
    Reg#(Bool) cancelled <- mkReg(False);

    rule tick;
        cycle <= cycle + 1;
    endrule
    rule beginFirst(cycle == 1);
        blocked.enq(False);
        backoff.start(tuple2(True, False));
    endrule
    rule checkHeld(cycle == 80);
        held <= backoff.done;
    endrule
    rule releaseFifo(cycle == 100);
        blocked.deq;
    endrule
    rule consume(backoff.done && consumed == 0);
        blocked.enq(True); // Implicit FIFO readiness blocks this until releaseFifo.
        backoff.softRst;
        consumed <= consumed + 1;
    endrule
    rule beginCancel(cycle == 120);
        backoff.start(tuple2(True, False));
    endrule
    rule cancel(cycle == 170);
        backoff.softRst;
    endrule
    rule checkCancelled(cycle == 172);
        cancelled <= !backoff.done && backoff.available;
    endrule
    rule restart(cycle == 180);
        backoff.start(tuple2(True, False));
    endrule
    rule consumeRestart(backoff.done && cycle > 180);
        backoff.softRst;
        consumed <= consumed + 1;
    endrule
    rule finish(cycle == 250);
        if (held && cancelled && consumed == 2 && backoff.available && !backoff.done) begin
            $display("TEST_PASS csma_done_handshake");
            $finish(0);
        end
        else begin
            $display("TEST_FAIL csma_done_handshake held=%0d cancelled=%0d consumed=%0d",
                     held, cancelled, consumed);
            $finish(1);
        end
    endrule
endmodule

// D01: queue TX while receiving, and keep the channel output full for long enough
// to cross TX_END. Every accepted TX must still start/end once, in FIFO order.
module mkTestPhyTxBackpressure(Empty);
    PhyCore phy <- mkPhyYansWifi(1);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(4)) queued <- mkReg(0);
    Reg#(UInt#(4)) accepted <- mkReg(0);
    Reg#(UInt#(4)) forwarded <- mkReg(0);
    Reg#(UInt#(4)) started <- mkReg(0);
    Reg#(UInt#(4)) ended <- mkReg(0);
    Reg#(UInt#(32)) endHigh <- mkReg(0);
    Reg#(PhyFsmState) previousState <- mkReg(PHY_IDLE);
    Reg#(Bool) previousEnd <- mkReg(False);

    rule tick;
        cycle <= cycle + 1;
    endrule
    rule status;
        let s <- phy.getPhyStatus.get;
        previousState <= s.state;
        previousEnd <= s.txEnd;
        if (s.state == PHY_TX && previousState != PHY_TX) begin
`ifdef WEAK_RX_BURST
            if (started == 0 && cycle >= 500) begin
                $display("TEST_FAIL phy_tx_backpressure: hidden weak RX starved TX");
                $finish(1);
            end
`endif
            started <= started + 1;
        end
        if (s.txEnd && !previousEnd) ended <= ended + 1;
        if (s.txEnd) endHigh <= endHigh + 1;
    endrule
`ifdef WEAK_RX_BURST
    rule injectRx(cycle >= 100 && cycle < 1000);
`else
    rule injectRx(cycle == 100);
`endif
        let packet = getEmptyPhyEvent;
        packet.srcPhyId = 2;
        packet.dstPhyId = 3;
        packet.rfParam = RfParam{power: 1000, mcs: 7};
`ifdef WEAK_RX_BURST
        packet.rfParam.power = 74;
`endif
        packet.ppduLen = 1062;
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = 1062;
        phy.phyRxSrv.request.put(packet);
    endrule
    rule enqueue(cycle >= 102 && queued < 4);
        let packet = getEmptyMacEvent;
        packet.srcMacId = 1;
        packet.dstMacId = 0;
        packet.rfParam = RfParam{power: 1000, mcs: 7};
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = 1062;
        packet.mpduDigest.cacheAddr = zeroExtend(pack(queued));
        phy.lowMacTxSrv.request.put(packet);
        queued <= queued + 1;
    endrule
    rule acceptedTx;
        let response <- phy.lowMacTxSrv.response.get;
        accepted <= accepted + 1;
    endrule
    rule rxResponse;
        let response <- phy.phyRxSrv.response.get;
    endrule
    rule receive;
        let packet <- phy.lowMacRxClt.request.get;
        phy.lowMacRxClt.response.put(GenericResp{});
    endrule
    rule drain(cycle >= 180000);
        let packet <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
        if (packet.mpduDigest.cacheAddr != zeroExtend(pack(forwarded))) begin
            $display("TEST_FAIL phy_tx_backpressure: duplicate or reordered TX");
            $finish(1);
        end
        forwarded <= forwarded + 1;
    endrule
    rule finish(cycle == 400000);
        $display("RESULT queued=%0d accepted=%0d forwarded=%0d started=%0d ended=%0d endHigh=%0d",
                 queued, accepted, forwarded, started, ended, endHigh);
        if (queued == 4 && accepted == 4 && forwarded == 4 && started == 4
            && ended == 4 && endHigh == 4 && previousState == PHY_IDLE) begin
            $display("TEST_PASS phy_tx_backpressure");
            $finish(0);
        end
        else begin
            $display("TEST_FAIL phy_tx_backpressure: TX event was lost or held");
            $finish(1);
        end
    endrule
endmodule
