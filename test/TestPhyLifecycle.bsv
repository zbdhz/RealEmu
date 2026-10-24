import Types::*;
import ClientServer::*;
import PhyCore::*;
import GetPut::*;
import StmtFSM::*;
module mkTestPhyLifecycle(Empty);
    let phy <- mkPhyYansWifi(0);
    Reg#(UInt#(32)) clock <- mkReg(0);
    Reg#(UInt#(32)) good <- mkReg(0);
    Reg#(UInt#(32)) bad <- mkReg(0);
    Reg#(Bool) cca <- mkReg(False);
    Reg#(Bool) drain <- mkReg(True);
    Reg#(Bit#(32)) probeTag <- mkReg(0);
    rule tick;
        clock<=clock+1;
        if(clock>2000000) begin $display("FAIL PHY lifecycle watchdog"); $finish(1); end
    endrule
    rule status;
        let p <- phy.getPhyStatus.get; cca<=p.cca;
        if(p.fcsEn && !p.fcsCorrect) bad<=bad+1;
    endrule
    rule rx (drain);
        let f <- phy.lowMacRxClt.request.get; phy.lowMacRxClt.response.put(GenericResp{}); good<=good+1;
    endrule
    rule airResponse; let r <- phy.phyRxSrv.response.get; endrule
    rule txResponse; let r <- phy.lowMacTxSrv.response.get; endrule
    rule tx; let f <- phy.phyTxClt.request.get; phy.phyTxClt.response.put(GenericResp{}); endrule
    function Action signal(MacId source, Bit#(32) tag, MpduLen length, Mcs mcs, PowerDb power);
        return action
            let f=getEmptyPhyEvent; f.srcPhyId=source; f.dstPhyId=0; f.exchangeId=tag;
            f.rfParam.mcs=mcs; f.rfParam.power=power; f.ppduLen=length;
            f.mpduDigest.length=length; f.mpduDigest.frameType=2; phy.phyRxSrv.request.put(f);
        endaction;
    endfunction
    function Stmt at(Integer us, Action a);
        return seq await(clock==fromInteger(us*250)); action a; endaction endseq;
    endfunction
    function Stmt check(UInt#(32) expectedGood, UInt#(32) expectedBad);
        return seq action
            if(good!=expectedGood || bad!=expectedBad) begin
                $display("FAIL lifecycle t=%0d good=%0d/%0d bad=%0d/%0d",clock,good,expectedGood,bad,expectedBad); $finish(1);
            end
        endaction endseq;
    endfunction
    function Stmt writeReg(RegOffset off,Bit#(32) v);
        return seq
            action phy.phyRegSrv.request.put(RegAccessReq{regOffset:off,writeEnable:True,writeData:v}); endaction
            action let r <- phy.phyRegSrv.response.get; if(r.error) begin $display("FAIL PHY register write %h",off); $finish(1); end endaction
        endseq;
    endfunction
    function Stmt readEq(RegOffset off,Bit#(32) v);
        return seq
            action phy.phyRegSrv.request.put(RegAccessReq{regOffset:off,writeEnable:False,writeData:0}); endaction
            action let r <- phy.phyRegSrv.response.get;
                if(r.error || r.readData!=v) begin $display("FAIL PHY counter %h=%0d expected=%0d",off,r.readData,v); $finish(1); end
            endaction
        endseq;
    endfunction
    Stmt test=seq
        // A=[10,186), B=[110,286), C=[210,386). Both A and C fail.
        at(10,signal(1,1,1038,7,1422)); at(110,signal(2,1,1038,7,1422));
        at(210,signal(3,1,1038,7,1422));
        await(clock==270*250);
        action if(!cca) begin $display("FAIL missing interference tail CCA"); $finish(1); end endaction
        await(clock==400*250); check(0,2);
        // Adjacent frames, different MCS/length, no overlap at the boundary.
        at(500,signal(1,2,14,0,1422)); at(544,signal(2,2,1038,7,1422));
        await(clock==730*250); check(2,2);
        // Duplicate event cannot extend airtime or generate another delivery.
        at(800,signal(1,3,1038,7,1422)); at(820,signal(1,3,1038,7,1422));
        await(clock==1000*250); check(3,2);
        action if(cca) begin $display("FAIL duplicate extended signal"); $finish(1); end endaction
        // Tail of an external frame persists across our own TXEND.
        await(clock==1100*250);
        action let f=getEmptyMacEvent; f.mpduDigest.length=1038; f.rfParam.mcs=7;
            phy.lowMacTxSrv.request.put(toAirFrame(f,99)); endaction
        at(1200,signal(2,4,1038,7,1422)); at(1300,signal(3,4,1038,7,1422));
        await(clock==1500*250); check(3,3);
        writeReg(phy_diag_command_off,1);
        readEq(phy_diag_base_off,9); readEq(phy_diag_base_off+4,6);
        readEq(phy_diag_base_off+8,3); readEq(phy_diag_base_off+12,3);
        readEq(phy_diag_base_off+16,3); readEq(phy_diag_base_off+20,1);
        readEq(phy_diag_base_off+24,1);
        writeReg(phy_error_model_off,1); readEq(phy_error_model_off,1);
        // Deterministic endpoints of the supplied curve: high SINR=FFFF,
        // overlapping equal-power MCS7=0. Intermediate values are not used as BER.
        at(2000,signal(1,8,1038,7,1422)); at(2100,signal(2,8,1038,7,1422));
        at(2200,signal(3,8,1038,7,1422));
        await(clock==2400*250); check(3,5);
        writeReg(phy_diag_command_off,2); writeReg(phy_diag_command_off,1);
        readEq(phy_diag_base_off,0); readEq(phy_diag_base_off+12,0);
        action drain<=False; endaction
        for(probeTag<=20;probeTag<30;probeTag<=probeTag+1) seq
            action signal(1,probeTag,14,0,1422); endaction
            delay(50*250);
        endseq
        writeReg(phy_diag_command_off,1);
        readEq(phy_diag_base_off+8,10); readEq(phy_diag_base_off+32,2);
        action drain<=True; endaction
        delay(50);
        check(11,5);
        action $display("PASS PHY lifecycle: chain tail, exact boundary, metadata, duplicates, TX overlap"); $finish(0); endaction
    endseq;
    mkAutoFSM(test);
endmodule
