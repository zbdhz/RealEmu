import GetPut::*;
import Connectable::*;
import ClientServer::*;
import Types::*;
import MacCore::*;
import PhyCore::*;

// D01-D03 regression: real MAC + PHY, Types.US_CYCLES cycles/us, no internal forcing.
// External traffic arrives close to the first local transmit commitment.
function UInt#(32) modelCycles(Integer oldCycles);
    return fromInteger(oldCycles * valueOf(US_CYCLES) / 200);
endfunction

module mkTestMacPhyDeadlock(Empty);
    MacCore mac <- mkMacDCF(1);
    PhyCore phy <- mkPhyYansWifi(1);
    mkConnection(mac.lowMacTxClt, phy.lowMacTxSrv);
    mkConnection(phy.lowMacRxClt, mac.lowMacRxSrv);

    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) queued <- mkReg(0);
    Reg#(UInt#(32)) forwarded <- mkReg(0);
    Reg#(UInt#(32)) started <- mkReg(0);
    Reg#(UInt#(32)) ended <- mkReg(0);
    Reg#(Bool) lastTxEnd <- mkReg(False);
    Reg#(UInt#(32)) endHighCycles <- mkReg(0);
    Reg#(PhyFsmState) lastState <- mkReg(PHY_IDLE);
    Reg#(Bool) lastCca <- mkReg(False);
    Reg#(Bit#(32)) dcf <- mkReg('1);
    Reg#(Bit#(32)) fifo <- mkReg('1);
    Reg#(UInt#(2)) regResponse <- mkReg(0);

    rule clockTick;
        cycle <= cycle + 1;
    endrule

    rule status;
        let s <- phy.getPhyStatus.get;
        mac.phyStatus.put(s);
        lastState <= s.state;
        lastCca <= s.cca;
        lastTxEnd <= s.txEnd;
        if (s.txEnd) endHighCycles <= endHighCycles + 1;
        if (s.state == PHY_TX && lastState != PHY_TX) begin
            started <= started + 1;
            $display("TRACE cycle=%0d PHY_START", cycle);
        end
        if (s.txEnd && !lastTxEnd) begin
            ended <= ended + 1;
            $display("TRACE cycle=%0d PHY_END", cycle);
        end
    endrule

    rule configureRts(cycle == 1);
        mac.macRegSrv.request.put(RegAccessReq{
            writeEnable: True, regOffset: mac_rts_thresh_off,
`ifdef NO_RTS
            writeData: 65535
`else
            writeData: 100
`endif
        });
    endrule

    rule enqueue(cycle >= modelCycles(100) && queued < 2);
        let packet = getEmptyMacEvent;
        packet.srcMacId = 1;
        packet.dstMacId = 0;
        packet.rfParam = RfParam{power: 1000, mcs: 7};
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = 1062;
        packet.mpduDigest.cacheAddr = zeroExtend(pack(queued));
        mac.highMacTxSrv.request.put(packet);
        queued <= queued + 1;
    endrule

    // Drain every outbound request and response: no artificial downstream blockage.
    rule channelOut;
        let packet <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
        forwarded <= forwarded + 1;
        $display("TRACE cycle=%0d CHANNEL_OUT count=%0d frameSubtype=%0d",
                 cycle, forwarded + 1, packet.mpduDigest.frameSubType);
    endrule
    rule channelResponse;
        let response <- phy.phyRxSrv.response.get;
    endrule
    rule upperResponse;
        let response <- mac.highMacTxSrv.response.get;
    endrule
    rule upperReceive;
        let packet <- mac.highMacRxClt.request.get;
        mac.highMacRxClt.response.put(GenericResp{});
    endrule

`ifdef INJECT_CYCLE
    rule interfere(cycle == `INJECT_CYCLE);
        let packet = getEmptyPhyEvent;
        packet.srcPhyId = 2;
        packet.dstPhyId = 3;
        packet.rfParam = RfParam{power: 1000, mcs: 7};
        packet.ppduLen = 1062;
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = 1062;
`ifdef INJECT_CTS
        // Hidden-node equivalent: overhear the center replying to another source.
        packet.srcPhyId = 0;
        packet.dstPhyId = 2;
        packet.rfParam.mcs = 0;
        packet.ppduLen = 14;
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
        packet.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_CTS));
        packet.mpduDigest.length = 14;
`endif
        phy.phyRxSrv.request.put(packet);
        $display("TRACE cycle=%0d INJECT_OVERHEARD_FRAME type=%0d subtype=%0d", cycle,
                 packet.mpduDigest.frameType, packet.mpduDigest.frameSubType);
    endrule
`endif

`ifdef READ_BURST_START
    // Ordinary reads deliberately occupy the DCF scheduling slot across TX_END.
    rule busyReads(cycle >= `READ_BURST_START && cycle < `READ_BURST_END);
        mac.macRegSrv.request.put(RegAccessReq{
            writeEnable: False, regOffset: mac_slot_time_off, writeData: 0});
    endrule
`endif

    rule readDcf(cycle == modelCycles(3990000));
        mac.macRegSrv.request.put(RegAccessReq{
            writeEnable: False, regOffset: mac_dcf_state_off, writeData: 0});
    endrule
    rule readFifo(cycle == modelCycles(3990100));
        mac.macRegSrv.request.put(RegAccessReq{
            writeEnable: False, regOffset: mac_fifoin_count_off, writeData: 0});
    endrule
`ifdef PROBE_CYCLE
    // A single ordinary register read, at the backoff-completion boundary.
    rule boundaryRead(cycle == `PROBE_CYCLE);
        mac.macRegSrv.request.put(RegAccessReq{
`ifdef PROBE_WRITE
            // Keep slot=9 unchanged; exercise write scheduling without changing timing.
            writeEnable: True, regOffset: mac_slot_time_off, writeData: 9});
`else
            writeEnable: False, regOffset: mac_slot_time_off, writeData: 0});
`endif
        $display("TRACE cycle=%0d INJECT_REGISTER_READ", cycle);
    endrule
`endif
    rule receiveRegister;
        let response <- mac.macRegSrv.response.get;
        if (cycle >= modelCycles(3990000) && cycle < modelCycles(3990100)) dcf <= response.readData;
        if (cycle >= modelCycles(3990100)) fifo <= response.readData;
        regResponse <= regResponse + 1;
    endrule

    rule finish(cycle == modelCycles(4000000));
        $display("RESULT queued=%0d forwarded=%0d started=%0d ended=%0d dcf=%0d fifo=%0d phy=%0d cca=%0d",
                 queued, forwarded, started, ended, dcf, fifo, pack(lastState), lastCca);
        $display("TXEND_HIGH_CYCLES %0d", endHighCycles);
        if (queued == 2 && forwarded == 14 && started == 14 && ended == 14
            && dcf == 0 && fifo == 0 && lastState == PHY_IDLE && !lastCca
            && endHighCycles == 14) begin
            $display("TEST_PASS mac_phy_deadlock");
            $finish(0);
        end
        else begin
            $display("TEST_FAIL mac_phy_deadlock: requests must retry, finish and drain");
            $finish(1);
        end
    endrule
endmodule
