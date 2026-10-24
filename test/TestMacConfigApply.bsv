import Types::*;
import DReg::*;
import MacCore::*;
import CsmaUtils::*;
import GetPut::*;
import ClientServer::*;
import StmtFSM::*;

// Configure the production MAC through its register server, never its children.
module mkTestMacConfigApply(Empty);
    let mac <- mkMacDCF(0);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) injected <- mkReg(0);
    Reg#(UInt#(32)) txCycle <- mkReg(0);
    Reg#(UInt#(32)) txCount <- mkReg(0);
    Reg#(Bit#(32)) generation <- mkReg(0);
    Reg#(MacEvent) lastTx <- mkReg(getEmptyMacEvent);
    Reg#(Bool) txEndPulse <- mkDReg(False);
    Reg#(Bit#(32)) txTag <- mkReg(0);
    rule tick;
        cycle <= cycle + 1;
        if (cycle > fromInteger(5000 * valueOf(US_CYCLES))) begin
            $display("FAIL MAC config watchdog"); $finish(1);
        end
    endrule
    // PHY stub: events are accepted immediately, TX completion stays asserted.
    // Actual PHY airtime is tested separately by TestTimebase.
    rule drivePhy;
        let p = getEmptyPhyStatus;
        p.txEnd = txEndPulse; p.txExchangeId = txTag;
        mac.phyStatus.put(p);
    endrule
    rule observeTx;
        let f <- mac.lowMacTxClt.request.get;
        mac.lowMacTxClt.response.put(GenericResp{});
        txCycle <= cycle; txCount <= txCount + 1; lastTx <= toMacEvent(f); txTag <= f.exchangeId; txEndPulse <= True;
    endrule
    rule drainRxResponse;
        let r <- mac.lowMacRxSrv.response.get;
    endrule
    rule drainHighRx;
        let f <- mac.highMacRxClt.request.get;
        mac.highMacRxClt.response.put(GenericResp{});
    endrule
    rule drainHighTx;
        let r <- mac.highMacTxSrv.response.get;
    endrule
    function Stmt writeCfg(RegOffset off, Bit#(32) value, Bool expectError);
        return seq
            action mac.macRegSrv.request.put(RegAccessReq{regOffset:off, writeEnable:True, writeData:value}); endaction
            action
                let r <- mac.macRegSrv.response.get;
                if (r.error != expectError) begin
                    $display("FAIL write off=%h value=%0d error=%0d", off, value, r.error); $finish(1);
                end
                if (!expectError) generation <= generation + 1;
            endaction
        endseq;
    endfunction
    function Stmt readEq(RegOffset off, Bit#(32) value);
        return seq
            action mac.macRegSrv.request.put(RegAccessReq{regOffset:off, writeEnable:False, writeData:0}); endaction
            action
                let r <- mac.macRegSrv.response.get;
                if (r.error || r.readData != value) begin
                    $display("FAIL read off=%h got=%0d expected=%0d error=%0d", off, r.readData, value, r.error); $finish(1);
                end
            endaction
        endseq;
    endfunction
    function Action injectData(Bool receive);
        return action
            let f = getEmptyMacEvent; f.status = True;
            f.srcMacId = receive ? 1 : 0; f.dstMacId = receive ? 0 : 1;
            f.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
            f.mpduDigest.length = 100; f.rfParam.mcs = 7;
            if (receive) mac.lowMacRxSrv.request.put(toAirFrame(f, 0));
            else mac.highMacTxSrv.request.put(f);
            injected <= cycle;
        endaction;
    endfunction
    function Action checkIfs(Integer us, Bool ack);
        return action
            let elapsed = txCycle - injected;
            if (elapsed < fromInteger((us-1)*valueOf(US_CYCLES)) ||
                elapsed > fromInteger(us*valueOf(US_CYCLES)) + 32 ||
                isAckFrame(lastTx.mpduDigest) != ack) begin
                $display("FAIL IFS us=%0d elapsed=%0d ack=%0d", us, elapsed, ack); $finish(1);
            end
            $display("PASS IFS configured=%0dus measured=%0d cycles ack=%0d", us, elapsed, ack);
        endaction;
    endfunction
    Stmt test = seq
        delay(20);
        readEq(mac_us_cycles_off, fromInteger(valueOf(US_CYCLES)));
        readEq(mac_cfg_generation_off, 0);
        writeCfg(mac_cw_min_off, 0, False);
        writeCfg(mac_cw_max_off, 0, False);
        writeCfg(mac_retry_limit_off, 0, False);
        writeCfg(mac_timeout_off, 20, False);
        writeCfg(mac_difs_off, 34, False);
        readEq(mac_cw_exp_off, 0);
        action injectData(False); endaction
        await(txCount == 1);
        action checkIfs(34, False); endaction
        // This write is queued while waiting ACK: it must wait for timeout/drop.
        writeCfg(mac_difs_off, 70, False);
        action
            // Existing timeout starts at 1 and uses a free-running us tick.
            if (cycle - txCycle < fromInteger(18*valueOf(US_CYCLES))) begin
                $display("FAIL configuration applied during exchange"); $finish(1);
            end
            $display("PASS busy write waited for exchange completion: %0d cycles", cycle - txCycle);
        endaction
        action injectData(False); endaction
        await(txCount == 2);
        action checkIfs(70, False); endaction
        writeCfg(mac_sifs_off, 16, False);
        action injectData(True); endaction
        await(txCount == 3);
        action checkIfs(16, True); endaction
        writeCfg(mac_sifs_off, 30, False);
        writeCfg(mac_slot_time_off, 3, False);
        action injectData(True); endaction
        await(txCount == 4);
        action checkIfs(30, True); endaction
        // An explicit 135us reservation is honored without an artificial floor.
        action
            let f = getEmptyMacEvent; f.status = True;
            f.srcMacId = 1; f.dstMacId = 2;
            f.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
            f.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_RTS));
            f.mpduDigest.duration = 135;
            mac.lowMacRxSrv.request.put(toAirFrame(f, 0));
        endaction
        delay(10);
        action mac.macRegSrv.request.put(RegAccessReq{regOffset:mac_nav_remaining_off, writeEnable:False, writeData:0}); endaction
        action
            let r <- mac.macRegSrv.response.get;
            if (r.error || r.readData < 134 || r.readData > 135) begin
                $display("FAIL NAV config propagation nav=%0d", r.readData); $finish(1);
            end
            $display("PASS NAV honors received Duration: nav=%0dus", r.readData);
        endaction
        writeCfg(mac_cw_max_off, 10, False);
        writeCfg(mac_cw_min_off, 10, False);
        readEq(mac_cw_exp_off, 10);
        writeCfg(mac_sifs_off, 31, False);
        readEq(mac_cw_exp_off, 10);
        // Reject invalid values without truncation or partial application.
        writeCfg(mac_cw_max_off, 11, True);
        writeCfg(mac_cw_max_off, 9, True);
        writeCfg(mac_cw_min_off, 16, True);
        writeCfg(mac_slot_time_off, 0, True);
        writeCfg(mac_sifs_off, 65536, True);
        writeCfg(mac_retry_limit_off, 16, True);
        writeCfg(nav_en_h_off, 2, True);
        writeCfg(mac_us_cycles_off, 200, True);
        readEq(mac_cw_min_off, 10);
        readEq(mac_cw_max_off, 10);
        readEq(mac_slot_time_off, 3);
        readEq(mac_sifs_off, 31);
        readEq(mac_cfg_generation_off, generation);
        // Retries must grow CW; periodic config propagation must not reset it.
        writeCfg(mac_cw_min_off, 1, False);
        writeCfg(mac_cw_max_off, 4, False);
        writeCfg(mac_retry_limit_off, 2, False);
        action injectData(False); endaction
        await(txCount == 6);
        readEq(mac_cw_exp_off, 2);
        await(txCount == 7);
        readEq(mac_cw_exp_off, 3);
        // Final write waits for final timeout, then CW is back at its minimum.
        writeCfg(mac_difs_off, 34, False);
        readEq(mac_cw_exp_off, 1);
        readEq(mac_cfg_generation_off, generation);
        // A lost DATA after our CTS must not make future configuration hang.
        action
            let f = getEmptyMacEvent; f.status = True;
            f.srcMacId = 1; f.dstMacId = 0;
            f.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
            f.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_RTS));
            mac.lowMacRxSrv.request.put(toAirFrame(f, 0));
        endaction
        await(txCount == 8);
        action
            if (!isCtsFrame(lastTx.mpduDigest)) begin $display("FAIL missing CTS"); $finish(1); end
        endaction
        writeCfg(mac_sifs_off, 16, False);
        action
            if (cycle - txCycle < fromInteger(18*valueOf(US_CYCLES))) begin
                $display("FAIL config split CTS/DATA exchange"); $finish(1);
            end
            $display("PASS pending config recovered after CTS without DATA");
        endaction
        readEq(mac_cfg_generation_off, generation);
        action $display("PASS MAC config: propagation, timing, NAV, CW, validation, deferred apply, generation"); $finish(0); endaction
    endseq;
    mkAutoFSM(test);
endmodule
