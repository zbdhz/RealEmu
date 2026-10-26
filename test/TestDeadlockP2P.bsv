import GetPut::*;
import ClientServer::*;
import Connectable::*;
import Types::*;
import MacCore::*;
import PhyCore::*;

// Regression for the unchanged protocol: MCS 0..7 x RTS off/on, three packets
// per case. Use real MAC + PHY on both sides and require ACK completions too.
module mkTestDeadlockP2P(Empty);
    MacCore sender <- mkMacDCF(1);
    MacCore receiver <- mkMacDCF(0);
    PhyCore txPhy <- mkPhyYansWifi(1);
    PhyCore rxPhy <- mkPhyYansWifi(0);
    mkConnection(sender.lowMacTxClt, txPhy.lowMacTxSrv);
    mkConnection(sender.lowMacRxSrv, txPhy.lowMacRxClt);
    mkConnection(receiver.lowMacTxClt, rxPhy.lowMacTxSrv);
    mkConnection(receiver.lowMacRxSrv, rxPhy.lowMacRxClt);
    mkConnection(txPhy.phyTxClt, rxPhy.phyRxSrv);
    mkConnection(rxPhy.phyTxClt, txPhy.phyRxSrv);

    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(5)) caseId <- mkReg(0);
    Reg#(UInt#(2)) phase <- mkReg(0);
    Reg#(UInt#(8)) sent <- mkReg(0);
    Reg#(UInt#(8)) completed <- mkReg(0);
    Reg#(UInt#(8)) delivered <- mkReg(0);
    Reg#(Bit#(64)) seen <- mkReg(0);

    rule tick;
        cycle <= cycle + 1;
    endrule
    rule status;
        let a <- txPhy.getPhyStatus.get;
        let b <- rxPhy.getPhyStatus.get;
        sender.phyStatus.put(a);
        receiver.phyStatus.put(b);
    endrule
    rule configure(phase == 0 && caseId < 16);
        sender.macRegSrv.request.put(RegAccessReq{
            writeEnable: True, regOffset: mac_rts_thresh_off,
            writeData: caseId < 8 ? 65535 : 100});
        phase <= 1;
    endrule
    rule configured(phase == 1);
        let response <- sender.macRegSrv.response.get;
        if (response.error) begin
            $display("TEST_FAIL p2p: register configuration failed");
            $finish(1);
        end
        phase <= 2;
    endrule
    rule sendPacket(phase == 2 && sent < (zeroExtend(caseId) + 1) * 3);
        let packet = getEmptyMacEvent;
        packet.srcMacId = 1;
        packet.dstMacId = 0;
        packet.rfParam = RfParam{power: 1000, mcs: truncate(pack(caseId)) & 7};
        packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        packet.mpduDigest.length = 1062;
        packet.mpduDigest.cacheAddr = zeroExtend(pack(sent));
        sender.highMacTxSrv.request.put(packet);
        sent <= sent + 1;
    endrule
    rule complete;
        let response <- sender.highMacTxSrv.response.get;
        completed <= completed + 1;
    endrule
    rule receive;
        let packet <- receiver.highMacRxClt.request.get;
        receiver.highMacRxClt.response.put(GenericResp{});
        Bit#(6) index = truncate(packet.mpduDigest.cacheAddr);
        if (packet.srcMacId != 1 || packet.dstMacId != 0 || index >= 48 || seen[index] == 1) begin
            $display("TEST_FAIL p2p: wrong or duplicate DATA id=%0d", index);
            $finish(1);
        end
        seen <= seen | (1 << index);
        delivered <= delivered + 1;
    endrule
    rule advance(phase == 2 && completed == (zeroExtend(caseId) + 1) * 3);
        $display("CASE_PASS id=%0d mcs=%0d rts=%0d completed=%0d delivered=%0d",
                 caseId, pack(caseId) & 7, caseId >= 8, completed, delivered);
        caseId <= caseId + 1;
        phase <= 0;
    endrule
    rule finish(caseId == 16);
        if (sent == 48 && completed == 48 && delivered == 48 && seen == 'hffffffffffff) begin
            $display("TEST_PASS p2p_all_16_cases sent=48 completed=48 delivered=48");
            $finish(0);
        end
        else begin
            $display("TEST_FAIL p2p: mismatched counts sent=%0d completed=%0d delivered=%0d",
                     sent, completed, delivered);
            $finish(1);
        end
    endrule
    rule watchdog(cycle == 20000000);
        $display("TEST_FAIL p2p watchdog case=%0d sent=%0d completed=%0d delivered=%0d",
                 caseId, sent, completed, delivered);
        $finish(1);
    endrule
endmodule
