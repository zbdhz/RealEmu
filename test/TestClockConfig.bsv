import GetPut::*;
import ClientServer::*;
import StmtFSM::*;
import DReg::*;
import Types::*;
import MacCore::*;
import CsmaUtils::*;

module mkTestModelClock(Empty);
    TimeGen us <- mkUsGen(valueOf(US_CYCLES));
    Reg#(MacConfig) cfg <- mkReg(getDefaultMacCfg);
    TimeGen slot <- mkSlotGen(us, cfg);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) lastUs <- mkReg(0);
    Reg#(UInt#(32)) lastSlot <- mkReg(0);
    Reg#(UInt#(8)) ticks <- mkReg(0);
    Reg#(UInt#(8)) slots <- mkReg(0);
    rule tick;
        cycle <= cycle + 1;
    endrule
    rule changeSlot(cycle == fromInteger(2 * valueOf(US_CYCLES) + 3));
        let nextCfg = cfg;
        nextCfg.slot = 2;
        cfg <= nextCfg;
    endrule
    rule observeUs(us.get);
        if (cycle - lastUs != fromInteger(valueOf(US_CYCLES))) begin
            $display("TEST_FAIL clock tick delta=%0d", cycle - lastUs);
            $finish(1);
        end
        lastUs <= cycle;
        ticks <= ticks + 1;
    endrule
    rule observeSlot(slot.get);
        if (slots != 0 && cycle - lastSlot != fromInteger(2 * valueOf(US_CYCLES))) begin
            $display("TEST_FAIL slot phase delta=%0d", cycle - lastSlot);
            $finish(1);
        end
        lastSlot <= cycle;
        slots <= slots + 1;
    endrule
    rule finish(ticks == 16);
        if (slots >= 5) begin
            $display("TEST_PASS model_clock cycles_per_us=%0d ticks=%0d slots=%0d", valueOf(US_CYCLES), ticks, slots);
            $finish(0);
        end
        else begin
            $display("TEST_FAIL slot change did not take effect");
            $finish(1);
        end
    endrule
endmodule

// The public sample stream must switch with config, and never grow past CWmax.
module mkTestCwConfigSwitch(Empty);
    ExpBackOffGenerator generator <- mkExpBackoffGenerator(1);
    Reg#(UInt#(8)) count <- mkReg(0);
    Reg#(Bool) sawUpperHalf <- mkReg(False);
    function Action configure(ContWindowExp minimum, ContWindowExp maximum);
        return action
            let cfg = getDefaultMacCfg;
            cfg.cwMin = minimum;
            cfg.cwMax = maximum;
            generator.putmaccfg.put(cfg);
        endaction;
    endfunction
    function Stmt checkSamples(TimeSlot maximum, Bool expectUpperHalf);
        return seq
            action sawUpperHalf <= False; endaction
            for (count <= 0; count < 64; count <= count + 1) action
                let sample <- generator.next.get;
                if (sample > maximum) begin
                    $display("TEST_FAIL CW sample=%0d maximum=%0d", sample, maximum);
                    $finish(1);
                end
                if (sample > 1) sawUpperHalf <= True;
            endaction
            action
                if (expectUpperHalf && !sawUpperHalf) begin
                    $display("TEST_FAIL CW did not expand"); $finish(1);
                end
            endaction
        endseq;
    endfunction
    Stmt test = seq
        delay(10); // Fill the old default-window prefetch before reconfiguring.
        configure(0, 0);
        checkSamples(0, False);
        configure(1, 2);
        checkSamples(1, False);
        generator.incrCW;
        checkSamples(3, True);
        generator.incrCW; // At the maximum: must remain CW=3, not grow to 7.
        checkSamples(3, True);
        configure(10, 10);
        checkSamples(1023, True);
        configure(0, 0);
        checkSamples(0, False);
        action $display("TEST_PASS cw_config_switch_and_saturation"); $finish(0); endaction
    endseq;
    mkAutoFSM(test);
endmodule

// Observe actual ACK/DATA timing after writing the public MAC register interface.
module mkTestMacConfigApplied(Empty);
    MacCore mac <- mkMacDCF(1);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) began <- mkReg(0);
    Reg#(Bool) txEnded <- mkDReg(False);
    rule tick;
        cycle <= cycle + 1;
    endrule
    rule status;
        let s = getEmptyPhyStatus;
        s.txEnd = txEnded;
        mac.phyStatus.put(s);
    endrule
    rule deliveredData;
        let packet <- mac.highMacRxClt.request.get;
        mac.highMacRxClt.response.put(GenericResp{});
    endrule
    rule acceptedRx;
        let response <- mac.lowMacRxSrv.response.get;
    endrule
    function Stmt writeCfg(RegOffset offset, Bit#(32) value, Bool expectError);
        return seq
            mac.macRegSrv.request.put(RegAccessReq{writeEnable: True, regOffset: offset, writeData: value});
            action
                let r <- mac.macRegSrv.response.get;
                if (r.error != expectError) begin
                    $display("TEST_FAIL config write offset=%h value=%0d error=%0d", offset, value, r.error);
                    $finish(1);
                end
            endaction
        endseq;
    endfunction
    function MacEvent incoming(Bool nav);
        let packet = getEmptyMacEvent;
        packet.srcMacId = 0;
        packet.dstMacId = nav ? 2 : 1;
        packet.mpduDigest.frameType = nav ? fromInteger(valueOf(FC_TYPE_CONTROL)) : fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.frameSubType = nav ? fromInteger(valueOf(FC_CTRLSUB_RTS)) : 0;
        packet.mpduDigest.length = 100;
        return packet;
    endfunction
    function MacEvent outgoing();
        let packet = getEmptyMacEvent;
        packet.srcMacId = 1;
        packet.dstMacId = 0;
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = 100;
        return packet;
    endfunction
    function Stmt acknowledgeData;
        return seq
            action txEnded <= True; endaction
            delay(4);
            action
                let packet = getEmptyMacEvent;
                packet.srcMacId = 0;
                packet.dstMacId = 1;
                packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
                packet.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_ACK));
                mac.lowMacRxSrv.request.put(packet);
            endaction
            action let response <- mac.highMacTxSrv.response.get; endaction
            delay(4);
        endseq;
    endfunction
    Stmt test = seq
        writeCfg(mac_cw_min_off, 0, False);
        writeCfg(mac_cw_max_off, 0, False);
        writeCfg(mac_sifs_off, 3, False);
        writeCfg(mac_difs_off, 3, False);
        writeCfg(mac_slot_time_off, 1, False);
        writeCfg(mac_slot_time_off, 0, True);
        writeCfg(mac_cw_max_off, 11, True);
        action
            mac.lowMacRxSrv.request.put(incoming(False));
            began <= cycle;
        endaction
        action
            let ack <- mac.lowMacTxClt.request.get;
            mac.lowMacTxClt.response.put(GenericResp{});
            txEnded <= True;
            UInt#(32) delta = cycle - began;
            if (delta < fromInteger(2 * valueOf(US_CYCLES)) || delta > fromInteger(4 * valueOf(US_CYCLES) + 30)) begin
                $display("TEST_FAIL SIFS not applied delta=%0d", delta);
                $finish(1);
            end
        endaction
        delay(8);
        action mac.highMacTxSrv.request.put(outgoing()); began <= cycle; endaction
        action
            let data <- mac.lowMacTxClt.request.get;
            mac.lowMacTxClt.response.put(GenericResp{});
            UInt#(32) delta = cycle - began;
            if (delta < fromInteger(2 * valueOf(US_CYCLES)) || delta > fromInteger(4 * valueOf(US_CYCLES) + 50)) begin
                $display("TEST_FAIL DIFS/CW0 not applied delta=%0d", delta);
                $finish(1);
            end
        endaction
        writeCfg(mac_sifs_off, 20, True); // An active TX must keep its original configuration.
        acknowledgeData;
        writeCfg(mac_sig_time_off, 250, False);
        writeCfg(mac_ofdm_symbol_off, 7, False);
        writeCfg(mac_max_num_off, 40, False);
        writeCfg(mac_phy_delay_off, 0, False);
        action mac.lowMacRxSrv.request.put(incoming(True)); began <= cycle; endaction
        delay(10);
        mac.highMacTxSrv.request.put(outgoing());
        action
            let data <- mac.lowMacTxClt.request.get;
            mac.lowMacTxClt.response.put(GenericResp{});
            UInt#(32) delta = cycle - began;
            // Existing NAV floor: 2*SIFS + 2*slot + sigTime + 7*40 = 538 us.
            if (delta < fromInteger(538 * valueOf(US_CYCLES)) || delta > fromInteger(545 * valueOf(US_CYCLES))) begin
                $display("TEST_FAIL NAV config not applied delta=%0d", delta);
                $finish(1);
            end
        endaction
        acknowledgeData;
        action $display("TEST_PASS mac_config_applied"); $finish(0); endaction
    endseq;
    mkAutoFSM(test);
    rule watchdog(cycle == fromInteger(800 * valueOf(US_CYCLES)));
        $display("TEST_FAIL mac_config watchdog");
        $finish(1);
    endrule
endmodule
