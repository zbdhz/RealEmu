import GetPut::*;
import StmtFSM::*;
import DReg::*;
import RWire::*;
import Types::*;
import MacCore::*;
import CsmaUtils::*;

// CW=1时只可能抽到0或1个slot；非零退避必须等一个完整的9us slot。
// 多次错开相位开始竞争，防止自由运行slot的“下一拍”冒充一个完整slot。
module mkTestBackoffFullSlot(Empty);
    TimeGen us <- mkUsGen(valueOf(US_CYCLES));
    Reg#(MacConfig) cfg <- mkReg(getDefaultMacCfg);
    TimeGen slot <- mkSlotGen(us, cfg);
    Wire#(PhyStatus) status <- mkDWire(getEmptyPhyStatus);
    CsmaBackOff_IFC backoff <- mkCsmaCaBackOff(status, us, slot, 0);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) began <- mkReg(0);
    Reg#(UInt#(6)) count <- mkReg(0);
    Reg#(Bool) sawSlot <- mkReg(False);
    rule tick; cycle <= cycle + 1; endrule
    Stmt test = seq
        delay(10);
        action
            let c = getDefaultMacCfg;
            c.cwMin = 1; c.cwMax = 1; c.difs = 0;
            backoff.putmaccfg.put(c); cfg <= c;
        endaction
        for (count <= 0; count < 32; count <= count + 1) seq
            await(backoff.available);
            backoff.start(tuple2(False, True));
            await(backoff.getStatus == CSMA_BACKOFF);
            action began <= cycle; endaction
            await(backoff.done);
            action
                UInt#(32) elapsed = cycle - began;
                if (elapsed > 5) begin
                    sawSlot <= True;
                    if (elapsed < fromInteger(8 * valueOf(US_CYCLES) - 5)
                        || elapsed > fromInteger(9 * valueOf(US_CYCLES) + 6)) begin
                        $display("TEST_FAIL backoff_full_slot elapsed=%0d", elapsed); $finish(1);
                    end
                end
                backoff.softRst;
            endaction
            delay(fromInteger(11 * valueOf(US_CYCLES)));
        endseq
        action
            if (sawSlot) $display("TEST_PASS backoff_full_slot 32 phases");
            else $display("TEST_FAIL backoff_full_slot no nonzero draw");
            $finish(0);
        endaction
    endseq;
    mkAutoFSM(test);
    rule watchdog(cycle == fromInteger(3000 * valueOf(US_CYCLES)));
        $display("TEST_FAIL backoff_full_slot watchdog"); $finish(1);
    endrule
endmodule
