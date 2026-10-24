import Types::*;
import ReceptionModel::*;
import ClientServer::*;
import GetPut::*;
import StmtFSM::*;
module mkTestReceptionModel(Empty);
    let model <- mkReceptionModel(0);
    Reg#(UInt#(32)) cycles <- mkReg(0);
    rule tick;
        cycles<=cycles+1;
        if(cycles>10000) begin $display("FAIL chunk model watchdog"); $finish(1); end
    endrule
    function Action chunk(Bit#(32) tag, UInt#(32) duration, Bool first, Bool last, Bool collided, Bool bitMode);
        return action
            let f=getEmptyMacEvent; f.rfParam.power=1422; f.rfParam.mcs=7;
            model.request.put(RxChunk{frame:toAirFrame(f,tag),interference:1<<24,cycles:duration,
                header:False,first:first,last:last,headerEnd:False,collided:collided,bitModel:bitMode});
        endaction;
    endfunction
    function Stmt checkDecision(Bit#(32) tag,Bool success);
        return seq action
            let d <- model.response.get;
            if(d.frame.exchangeId!=tag || d.success!=success) begin
                $display("FAIL chunk result tag=%0d/%0d success=%0d/%0d",d.frame.exchangeId,tag,d.success,success); $finish(1);
            end
        endaction endseq;
    endfunction
    Stmt test=seq
        action model.perSrv.request.put(PerCfg{perIn:7*1120+1119,perOut:65000}); endaction
        action let r <- model.perSrv.response.get; endaction
        action chunk(1,100,True,True,False,True); endaction
        checkDecision(1,True);
        action chunk(2,100000,True,True,False,True); endaction
        checkDecision(2,False);
        action chunk(3,100,True,False,False,True); endaction
        action chunk(3,100000,False,True,False,True); endaction
        checkDecision(3,False);
        action model.perSrv.request.put(PerCfg{perIn:7*1120+1119,perOut:65535}); endaction
        action let r <- model.perSrv.response.get; endaction
        // Mode 1 uses chunk SINR/PRR, not the mode 0 collision veto.
        action chunk(4,100000,True,True,True,True); endaction
        checkDecision(4,True);
        action chunk(5,100000,True,True,True,False); endaction
        checkDecision(5,False);
        action $display("PASS reception model: duration weighting, chunk accumulation, mode separation, tags"); $finish(0); endaction
    endseq;
    mkAutoFSM(test);
endmodule
