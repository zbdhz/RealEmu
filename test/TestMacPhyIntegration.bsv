import Types::*;
import ClientServer::*;
import MacCore::*;
import PhyCore::*;
import FrameTiming::*;
import CsmaUtils::*;
import Vector::*;
import GetPut::*;
import Connectable::*;
import StmtFSM::*;
module mkTestMacPhyIntegration(Empty);
    Vector#(3,MacCore) mac <- genWithM(compose(mkMacDCF,fromInteger));
    Vector#(3,PhyCore) phy <- genWithM(compose(mkPhyYansWifi,fromInteger));
    Vector#(3,Reg#(UInt#(32))) complete <- replicateM(mkReg(0));
    Vector#(3,Reg#(UInt#(32))) received <- replicateM(mkReg(0));
    Reg#(UInt#(32)) clock <- mkReg(0);
    Reg#(Bit#(5)) caseId <- mkReg(0);
    Reg#(Bool) hidden <- mkReg(False);
    Reg#(Bool) fastControl <- mkReg(False);
    Reg#(Bool) sawCts <- mkReg(False);
    Reg#(UInt#(32)) protectionEnd <- mkReg(0);
    Reg#(Bool) contenderSent <- mkReg(False);
    rule tick;
        clock<=clock+1;
        if(clock>8000000) begin $display("FAIL integration watchdog case=%0d",caseId); $finish(1); end
    endrule
    for(Integer i=0;i<3;i=i+1) begin
        mkConnection(mac[i].lowMacTxClt,phy[i].lowMacTxSrv);
        mkConnection(phy[i].lowMacRxClt,mac[i].lowMacRxSrv);
        rule relayStatus;
            let p <- phy[i].getPhyStatus.get; mac[i].phyStatus.put(p);
            if(p.rxStart || p.rxHeader || p.rxEnd || p.txEnd)
                $display("INTEGRATION PHY node=%0d raw=%0d hdr=%0d end=%0d crc=%0d txend=%0d at=%0d",i,p.rxStart,p.rxHeader,p.rxEnd,p.fcsCorrect,p.txEnd,clock);
        endrule
        rule completeTx;
            let r <- mac[i].highMacTxSrv.response.get; complete[i]<=complete[i]+1;
        endrule
        rule receiveData;
            let f <- mac[i].highMacRxClt.request.get; mac[i].highMacRxClt.response.put(GenericResp{});
            received[i]<=received[i]+1;
            $display("INTEGRATION RX node=%0d src=%0d tag=%0d at=%0d",i,f.srcMacId,f.mpduDigest.cacheAddr,clock);
        endrule
        rule drainAir; let r <- phy[i].phyRxSrv.response.get; endrule
        rule channel;
            let f <- phy[i].phyTxClt.request.get; phy[i].phyTxClt.response.put(GenericResp{});
            $display("INTEGRATION AIR node=%0d type=%0d subtype=%0d mcs=%0d len=%0d tag=%0d at=%0d",i,f.mpduDigest.frameType,f.mpduDigest.frameSubType,f.rfParam.mcs,f.ppduLen,f.exchangeId,clock);
            for(Integer j=0;j<3;j=j+1) if(i!=j) begin
                let air=f;
                air.rfParam.power = (i==0 && j==2) || (i==2 && j==0) ? 74 : 1422;
                phy[j].phyRxSrv.request.put(air);
            end
            if(i==0 && isDataFrame(f.mpduDigest) && f.mpduDigest.duration!=(fastControl ? 44 : 60)) begin $display("FAIL DATA Duration"); $finish(1); end
            if(i==0 && isRtsFrame(f.mpduDigest)) begin
                let original=getEmptyMacEvent; original.rfParam.mcs=truncate(caseId & 7);
                if(hidden || fastControl) original.rfParam.mcs=7;
                original.mpduDigest.length=1038;
                let controlCfg=getDefaultMacCfg; if(fastControl) controlCfg.controlMcs=4;
                if(f.mpduDigest.duration!=rtsDuration(original,controlCfg)) begin $display("FAIL RTS Duration"); $finish(1); end
            end
            if(i==1 && isCtsFrame(f.mpduDigest) && hidden && f.dstPhyId==0) begin
                if(f.mpduDigest.duration!=252) begin $display("FAIL CTS Duration=%0d",f.mpduDigest.duration); $finish(1); end
                sawCts<=True; protectionEnd<=clock+(44+252)*250;
            end
            if(i==2 && isDataFrame(f.mpduDigest) && hidden) begin
                if(clock<protectionEnd) begin $display("FAIL hidden sender violated CTS NAV now=%0d end=%0d",clock,protectionEnd); $finish(1); end
                contenderSent<=True;
            end
        endrule
    end
    function Stmt writeReg(Integer node, RegOffset off, Bit#(32) value);
        return seq
            action mac[node].macRegSrv.request.put(RegAccessReq{regOffset:off,writeEnable:True,writeData:value}); endaction
            action let r <- mac[node].macRegSrv.response.get;
                if(r.error) begin $display("FAIL integration config node=%0d off=%h",node,off); $finish(1); end
            endaction
        endseq;
    endfunction
    function Action send(Integer node,Mcs mcs,Bit#(64) seqno);
        return action
            let f=getEmptyMacEvent; f.srcMacId=fromInteger(node); f.dstMacId=1;
            f.mpduDigest.frameType=2; f.mpduDigest.length=1038; f.mpduDigest.cacheAddr=seqno;
            f.rfParam.mcs=mcs; f.rfParam.power=1422;
            mac[node].highMacTxSrv.request.put(f);
        endaction;
    endfunction
    Stmt test=seq
        writeReg(0,mac_cw_min_off,0); writeReg(0,mac_cw_max_off,0);
        writeReg(0,mac_retry_limit_off,0); writeReg(0,mac_timeout_off,40);
        writeReg(2,mac_cw_min_off,0); writeReg(2,mac_cw_max_off,0);
        writeReg(2,mac_retry_limit_off,0); writeReg(2,mac_timeout_off,40);
        for(caseId<=0;caseId<16;caseId<=caseId+1) seq
            writeReg(0,mac_rts_thresh_off,caseId<8 ? 65535 : 0);
            action send(0,truncate(caseId & 7),zeroExtend(caseId)+1); endaction
            await(complete[0]==zeroExtend(unpack(caseId))+1);
            action
                if(received[1]!=zeroExtend(unpack(caseId))+1) begin $display("FAIL integrated delivery case=%0d received=%0d",caseId,received[1]); $finish(1); end
                $display("PASS integration MCS%0d RTS=%0d",caseId&7,caseId>=8);
            endaction
        endseq
        delay(500*250);
        action hidden<=True; endaction
        action send(0,7,100); endaction
        await(sawCts);
        action send(2,7,200); endaction
        await(complete[0]==17 && complete[2]==1);
        action
            if(!contenderSent || received[1]!=18) begin $display("FAIL hidden integration recv=%0d",received[1]); $finish(1); end
        endaction
        delay(500*250);
        action hidden<=False; fastControl<=True; endaction
        writeReg(0,mac_control_mcs_off,4); writeReg(1,mac_control_mcs_off,4);
        action send(0,7,300); endaction
        await(complete[0]==18);
        action
            if(received[1]!=19) begin $display("FAIL 24Mbps control integration"); $finish(1); end
            $display("PASS MAC PHY integration: 16 MCS/RTS cases, hidden CTS NAV, 24Mbps controls"); $finish(0);
        endaction
    endseq;
    mkAutoFSM(test);
endmodule
