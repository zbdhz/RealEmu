import Types::*;
import CsmaUtils::*;
import PhyCore::*;
import GetPut::*;
import ClientServer::*;
import StmtFSM::*;

// Independent cycle measurements, including real PHY TX (with its pipeline).
module mkTestTimebase(Empty);
    let us <- mkUsGen(valueOf(US_CYCLES));
    Reg#(MacConfig) cfg <- mkReg(getDefaultMacCfg);
    let slot <- mkSlotGen(us, cfg);
    let phy <- mkPhyYansWifi(0);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) lastUs <- mkReg(0);
    Reg#(UInt#(32)) lastSlot <- mkReg(0);
    Reg#(UInt#(32)) slotsSeen <- mkReg(0);
    Reg#(Bool) slotChanged <- mkReg(False);
    Reg#(UInt#(32)) txStart <- mkReg(0);
    Reg#(Bool) transmitting <- mkReg(False);
    Reg#(Bool) txDone <- mkReg(False);

    rule tick;
        cycle <= cycle + 1;
        if (cycle > fromInteger(300 * valueOf(US_CYCLES))) begin
            $display("FAIL timebase watchdog"); $finish(1);
        end
    endrule
    rule checkUs (us.get);
        if (cycle - lastUs != fromInteger(valueOf(US_CYCLES))) begin
            $display("FAIL us period=%0d", cycle - lastUs); $finish(1);
        end
        lastUs <= cycle;
    endrule
    rule checkSlot (slot.get && cycle != fromInteger(25 * valueOf(US_CYCLES)) + 10);
        // First pulse has one cycle of registered pulse latency.
        if (lastSlot != 0 && cycle - lastSlot != fromInteger(valueOf(US_CYCLES)) * zeroExtend(unpack(cfg.slot))) begin
            $display("FAIL slot period=%0d slot_us=%0d", cycle - lastSlot, cfg.slot); $finish(1);
        end
        slotsSeen <= slotsSeen + 1;
        lastSlot <= cycle;
    endrule
    // Reduce 9 -> 3 while the old slot counter is already above 3.
    rule changeSlot (cycle == fromInteger(25 * valueOf(US_CYCLES)) + 10);
        let c = cfg; c.slot = 3; cfg <= c;
        lastSlot <= 0;
        slotChanged <= True;
    endrule
    rule checkSlotRestart (cycle == fromInteger(30 * valueOf(US_CYCLES)));
        if (!slotChanged || lastSlot == 0) begin
            $display("FAIL slot counter did not restart after reduction"); $finish(1);
        end
    endrule
    rule drainTx;
        let f <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
    endrule
    rule drainMac;
        let r <- phy.lowMacTxSrv.response.get;
    endrule
    rule observePhy;
        let p <- phy.getPhyStatus.get;
        if (p.state == PHY_TX && !transmitting && !txDone) begin
            txStart <= cycle;
            transmitting <= True;
        end
        if (transmitting && p.state == PHY_IDLE) begin
            let duration = cycle - txStart;
            // 1038-byte PSDU, MCS7: 20 + 4*ceil((8304+22)/216) = 176 us.
            // Existing divider/state pipeline adds a small fixed cycle delay.
            if (duration < fromInteger(176 * valueOf(US_CYCLES)) ||
                duration > fromInteger(176 * valueOf(US_CYCLES)) + 64) begin
                $display("FAIL PHY duration=%0d cycles", duration); $finish(1);
            end
            $display("PASS PHY 1038B/MCS7: airtime=176us measured=%0d cycles overhead=%0d",
                duration, duration - fromInteger(176 * valueOf(US_CYCLES)));
            transmitting <= False;
            txDone <= True;
        end
    endrule
    Stmt test = seq
        delay(100);
        action
            let f = getEmptyMacEvent;
            f.dstMacId = 1; f.mpduDigest.length = 1038; f.rfParam.mcs = 7;
            phy.lowMacTxSrv.request.put(toAirFrame(f, 0));
        endaction
        await(txDone);
        action
            if (slotsSeen < 10) begin $display("FAIL missing slot pulses"); $finish(1); end
            $display("PASS timebase: cycles/us=%0d, us pulses, 9us slots, 9->3us reconfiguration", valueOf(US_CYCLES));
            $finish(0);
        endaction
    endseq;
    mkAutoFSM(test);
endmodule
