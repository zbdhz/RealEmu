import Types::*;
import ClientServer::*;
import MacCore::*;
import CsmaUtils::*;
import GetPut::*;
import StmtFSM::*;
import DReg::*;
module mkTestResponseTimeout(Empty);
    let mac <- mkMacDCF(0);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) transmissions <- mkReg(0);
    Reg#(UInt#(32)) completions <- mkReg(0);
    Reg#(AirFrame) lastTx <- mkReg(toAirFrame(getEmptyMacEvent,0));
    Reg#(AirFrame) stale <- mkReg(toAirFrame(getEmptyMacEvent,0));
    Reg#(Bool) txEnd <- mkDReg(False);
    Reg#(Bool) crcFailure <- mkDReg(False);
    Reg#(Bool) rxStart <- mkDReg(False);
    Reg#(Bool) rxHeader <- mkDReg(False);
    Reg#(AirFrame) response <- mkReg(toAirFrame(getEmptyMacEvent,0));
    rule tick;
        cycle<=cycle+1;
        if(cycle>2000000) begin $display("FAIL response watchdog"); $finish(1); end
    endrule
    rule status;
        let p=getEmptyPhyStatus; p.txEnd=txEnd; p.txExchangeId=lastTx.exchangeId;
        p.rxStart=rxStart; p.rxHeader=rxHeader; p.rxFrame=response; p.rxStartFrame=response;
        p.fcsEn=crcFailure; p.fcsCorrect=False;
        mac.phyStatus.put(p);
    endrule
    rule tx;
        let f <- mac.lowMacTxClt.request.get; mac.lowMacTxClt.response.put(GenericResp{});
        lastTx<=f; txEnd<=True; transmissions<=transmissions+1;
    endrule
    rule done;
        let r <- mac.highMacTxSrv.response.get; completions<=completions+1;
    endrule
    rule lowResp; let r <- mac.lowMacRxSrv.response.get; endrule
    rule highRx; let f <- mac.highMacRxClt.request.get; mac.highMacRxClt.response.put(GenericResp{}); endrule
    function Stmt writeReg(RegOffset off, Bit#(32) value);
        return seq
            action mac.macRegSrv.request.put(RegAccessReq{regOffset:off,writeEnable:True,writeData:value}); endaction
            action let r <- mac.macRegSrv.response.get; if(r.error) begin $display("FAIL response config %h",off); $finish(1); end endaction
        endseq;
    endfunction
    function Stmt readEq(RegOffset off, Bit#(32) expected);
        return seq
            action mac.macRegSrv.request.put(RegAccessReq{regOffset:off,writeEnable:False,writeData:0}); endaction
            action let r <- mac.macRegSrv.response.get;
                if(r.error || r.readData!=expected) begin $display("FAIL diagnostic off=%h got=%0d expected=%0d",off,r.readData,expected); $finish(1); end
            endaction
        endseq;
    endfunction
    function Action inject();
        return action
            let f=getEmptyMacEvent; f.dstMacId=1; f.rfParam.mcs=7;
            f.mpduDigest.frameType=2; f.mpduDigest.length=1038; f.mpduDigest.cacheAddr=55;
            mac.highMacTxSrv.request.put(f);
        endaction;
    endfunction
    function AirFrame ack(AirFrame f);
        let a=toAirFrame(setAckFrame(1,toMacEvent(f)),f.exchangeId); a.status=True; return a;
    endfunction
    function Stmt receiveAck(AirFrame a);
        return seq
            action response<=a; rxStart<=True; endaction
            delay(20*250);
            action rxHeader<=True; endaction
            delay(24*250);
            action mac.lowMacRxSrv.request.put(a); endaction
        endseq;
    endfunction
    Stmt test=seq
        writeReg(mac_cw_min_off,0); writeReg(mac_cw_max_off,0);
        writeReg(mac_retry_limit_off,0); writeReg(mac_timeout_off,30);
        action inject; endaction
        await(transmissions==1);
        delay(20*250);
        receiveAck(ack(lastTx)); // Completes 64us after TXEND, beyond 30us START budget.
        await(completions==1);
        writeReg(mac_diag_command_off,1);
        readEq(mac_diag_base_off+12,1); readEq(mac_diag_base_off+20,0);
        action $display("PASS response start extends past original timeout"); endaction
        // No CTS, one attempt and one final drop.
        writeReg(mac_rts_thresh_off,0);
        action inject; endaction
        await(completions==2);
        writeReg(mac_diag_command_off,1);
        readEq(mac_diag_base_off+8,1); readEq(mac_diag_base_off+16,1); readEq(mac_diag_base_off+24,1);
        // No ACK, retryLimit=6 means seven attempts, never eight.
        writeReg(mac_rts_thresh_off,65535); writeReg(mac_retry_limit_off,6);
        action inject; endaction
        await(completions==3);
        action if(transmissions!=9) begin $display("FAIL retry attempts=%0d",transmissions); $finish(1); end endaction
        writeReg(mac_diag_command_off,1);
        readEq(mac_diag_base_off+4,8); readEq(mac_diag_base_off+20,7); readEq(mac_diag_base_off+24,2);
        readEq(mac_cw_exp_off,0);
        // A late ACK from attempt one must not complete attempt two.
        writeReg(mac_retry_limit_off,1);
        action inject; endaction
        await(transmissions==10);
        action stale<=ack(lastTx); endaction
        await(transmissions==11);
        action mac.lowMacRxSrv.request.put(stale); endaction
        delay(50);
        action
            if(completions!=3) begin $display("FAIL stale ACK completed retry"); $finish(1); end
            let wrong=ack(lastTx); wrong.srcMacId=2;
            mac.lowMacRxSrv.request.put(wrong);
        endaction
        delay(50);
        receiveAck(ack(lastTx));
        await(completions==4);
        writeReg(mac_diag_command_off,1);
        readEq(mac_diag_base_off,4); readEq(mac_diag_base_off+12,2);
        readEq(mac_diag_base_off+16,1); readEq(mac_diag_base_off+20,8);
        readEq(mac_diag_base_off+24,2); readEq(mac_diag_base_off+28,4);
        readEq(mac_diag_base_off+36,2); readEq(mac_diag_base_off+40,0);
        // A wrong response TYPE must not complete a DATA exchange.
        writeReg(mac_retry_limit_off,0);
        action inject; endaction
        await(transmissions==12);
        action
            let wrong=toAirFrame(setCtsFrame(1,toMacEvent(lastTx)),lastTx.exchangeId); wrong.status=True;
            mac.lowMacRxSrv.request.put(wrong);
        endaction
        await(completions==5);
        // A header can succeed while payload CRC fails. Completion remains bounded.
        action inject; endaction
        await(transmissions==13);
        action response<=ack(lastTx); rxStart<=True; endaction
        delay(20*250);
        action rxHeader<=True; endaction
        delay(24*250);
        action crcFailure<=True; endaction
        await(completions==6);
        writeReg(mac_diag_command_off,1);
        readEq(mac_diag_base_off,6); readEq(mac_diag_base_off+12,2);
        readEq(mac_diag_base_off+20,10); readEq(mac_diag_base_off+24,4);
        readEq(mac_diag_base_off+28,6); readEq(mac_diag_base_off+36,3);
        readEq(mac_diag_base_off+44,1);
        // Clear affects live values only; the previous snapshot is immutable.
        writeReg(mac_diag_command_off,2); readEq(mac_diag_base_off,6);
        writeReg(mac_diag_command_off,1); readEq(mac_diag_base_off,0); readEq(mac_diag_base_off+28,0);
        action $display("PASS response timeout: extension, no CTS/ACK, seven attempts, stale/peer rejection, diagnostic snapshot/clear"); $finish(0); endaction
    endseq;
    mkAutoFSM(test);
endmodule
