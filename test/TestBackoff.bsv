import Types::*;
import CsmaUtils::*;
import MacCore::*;
import GetPut::*;
import StmtFSM::*;
import DReg::*;
module mkTestBackoff(Empty);
    let random <- mkExpBackoffGenerator(0);
    let other <- mkExpBackoffGenerator(1);
    Reg#(MacConfig) cfg <- mkReg(getDefaultMacCfg);
    let us <- mkUsGen(valueOf(US_CYCLES));
    let slots <- mkSlotGen(us,cfg);
    Wire#(PhyStatus) status <- mkBypassWire;
    Reg#(Bool) busy <- mkReg(False);
    Reg#(Bool) bad <- mkDReg(False);
    let bo <- mkCsmaCaBackOff(status,us,slots,0);
    Reg#(UInt#(32)) clock <- mkReg(0);
    Reg#(UInt#(32)) resumed <- mkReg(0);
    Reg#(TimeSlot) sample <- mkReg(0);
    rule tick;
        clock <= clock+1;

        if(clock>200000) begin $display("FAIL backoff watchdog"); $finish(1); end
    endrule
    rule driveStatus;
        let p=getEmptyPhyStatus; p.cca=busy; p.fcsEn=bad; p.fcsCorrect=False; status <= p;
    endrule
    Stmt test=seq
        action let c=getDefaultMacCfg; c.cwMin=0; c.cwMax=10; random.putmaccfg.put(c); endaction
        repeat(8) action let n <- random.next.get; if(n!=0) begin $display("FAIL prefetched CW"); $finish(1); end endaction
        repeat(12) action random.incrCW; endaction
        action if(random.currentCW!=10) begin $display("FAIL CW saturation"); $finish(1); end endaction
        action let n <- random.next.get; sample <= n; endaction
        action random.resetCW; endaction
        action let n <- random.next.get; if(n!=0) begin $display("FAIL CW reset"); $finish(1); end endaction
        action
            let c=getDefaultMacCfg; c.cwMin=3; c.cwMax=3; c.backoffSeed=5; c.slot=2; c.difs=3; c.eifs=7;
            cfg<=c; bo.putmaccfg.put(c); random.putmaccfg.put(c); other.putmaccfg.put(c);
        endaction
        action let n <- random.next.get; let m <- other.next.get;
            if(n!=5 || n==m) begin $display("FAIL seeded samples n=%0d m=%0d",n,m); $finish(1); end
        endaction
        action bo.start(tuple2(False,True)); endaction
        await(bo.getStatus==CSMA_BACKOFF);
        action if(bo.remainingSlots!=5) begin $display("FAIL initial slots"); $finish(1); end endaction
        delay(250); // Half a slot; it must be discarded on busy.
        action busy<=True; bad<=True; endaction
        delay(500);
        action busy<=False; resumed<=clock; endaction
        await(bo.getStatus==CSMA_BACKOFF);
        action
            if(clock-resumed<7*250 || bo.remainingSlots!=5) begin
                $display("FAIL frozen EIFS/slots elapsed=%0d slots=%0d",clock-resumed,bo.remainingSlots); $finish(1);
            end
            resumed<=clock;
        endaction
        await(bo.remainingSlots==4);
        action if(clock-resumed<490) begin $display("FAIL partial slot reused"); $finish(1); end endaction
        action busy<=True; endaction
        delay(500);
        action busy<=False; resumed<=clock; endaction
        await(bo.getStatus==CSMA_BACKOFF);
        action
            if(clock-resumed<3*250 || clock-resumed>3*250+10 || bo.remainingSlots!=4) begin
                $display("FAIL resumed DIFS elapsed=%0d slots=%0d",clock-resumed,bo.remainingSlots); $finish(1);
            end
        endaction
        // Serve a SIFS response while preserving this packet's residual CW.
        action bo.suspendContention; endaction
        await(bo.available);
        action bo.start(tuple2(True,False)); endaction
        await(bo.done);
        action bo.start(tuple2(False,True)); resumed<=clock; endaction
        await(bo.getStatus==CSMA_BACKOFF);
        action
            if(bo.remainingSlots!=4 || clock-resumed<3*250) begin
                $display("FAIL contention lost across SIFS response slots=%0d",bo.remainingSlots); $finish(1);
            end
        endaction
        await(bo.done);
        action
            let f=getEmptyMacEvent; f.status=True; f.dstMacId=1; f.mpduDigest.duration=100;
            bo.navctrl.handleFrame(f);
        endaction
        delay(3);
        action let f=getEmptyMacEvent; f.status=True; f.dstMacId=1; f.mpduDigest.duration=1; bo.navctrl.handleFrame(f); endaction
        delay(3);
        action if(bo.navctrl.getNavValue<99) begin $display("FAIL short NAV replaced long"); $finish(1); end endaction
        action bo.navctrl.resetNav; endaction
        delay(3);
        action if(bo.navctrl.isNavWaiting) begin $display("FAIL NAV reset"); $finish(1); end endaction
        action let f=getEmptyMacEvent; f.status=True; f.dstMacId=1; f.mpduDigest.duration=0; bo.navctrl.handleFrame(f); endaction
        delay(3);
        action if(bo.navctrl.isNavWaiting) begin $display("FAIL NAV artificial minimum"); $finish(1); end endaction
        action $display("PASS backoff: on-demand CW, seeds, saturation, freeze, EIFS, full slots, NAV"); $finish(0); endaction
    endseq;
    mkAutoFSM(test);
endmodule
