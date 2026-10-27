import GetPut::*;
import ClientServer::*;
import Connectable::*;
import Types::*;
import MacCore::*;
import PhyCore::*;

// 一个正确帧结束5us后又来了RTS。ACK/CTS应在第一个帧结束16us后发送，
// 不能等第二个RTS的52us接收结束，也不能因其CCA/NAV重新等待SIFS。
module mkTestSifsResponse(Empty);
    MacCore mac <- mkMacDCF(0);
    PhyCore phy <- mkPhyYansWifi(0);
    mkConnection(mac.lowMacTxClt, phy.lowMacTxSrv);
    mkConnection(phy.lowMacRxClt, mac.lowMacRxSrv);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) started <- mkReg(0);
    Reg#(UInt#(3)) sent <- mkReg(0);
`ifdef SIFS_CTS
    Integer firstUs = 52;
    FrameSubType expectedSubtype = fromInteger(valueOf(FC_CTRLSUB_CTS));
`else
    Integer firstUs = 180;
    FrameSubType expectedSubtype = fromInteger(valueOf(FC_CTRLSUB_ACK));
`endif
    rule tick; cycle <= cycle + 1; endrule
    rule status;
        let s <- phy.getPhyStatus.get;
        mac.phyStatus.put(s);
    endrule
    rule upperRx;
        let p <- mac.highMacRxClt.request.get;
        mac.highMacRxClt.response.put(GenericResp{});
    endrule
    rule response; let ignored <- phy.phyRxSrv.response.get; endrule
    rule first(cycle == 100);
        let p = getEmptyPhyEvent;
        p.srcPhyId = 1; p.dstPhyId = 0;
        p.rfParam = RfParam{power: 1000, mcs: 7};
        p.ppduLen = 1064; p.mpduDigest.length = 1064;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        p.mpduDigest.duration = 60;
`ifdef SIFS_CTS
        p.rfParam.mcs = 0; p.ppduLen = 20; p.mpduDigest.length = 20;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
        p.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_RTS));
        p.mpduDigest.duration = 316;
`endif
        phy.phyRxSrv.request.put(p);
    endrule
    rule interfere(cycle == 100 + fromInteger((firstUs + 5) * valueOf(US_CYCLES)));
        let p = getEmptyPhyEvent;
        p.srcPhyId = 2; p.dstPhyId = 0;
        p.rfParam = RfParam{power: 1000, mcs: 0};
        p.ppduLen = 20; p.mpduDigest.length = 20;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
        p.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_RTS));
        phy.phyRxSrv.request.put(p);
    endrule
    rule channel;
        let p <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
        if (p.mpduDigest.frameSubType != expectedSubtype || p.dstPhyId != 1) begin
            $display("TEST_FAIL sifs_response wrong response"); $finish(1);
        end
        started <= cycle; sent <= sent + 1;
    endrule
    rule finish(cycle == fromInteger(400 * valueOf(US_CYCLES)));
        UInt#(32) elapsed = started - 100;
        UInt#(32) ideal = fromInteger((firstUs + 16) * valueOf(US_CYCLES));
        if (sent == 1 && elapsed > ideal - fromInteger(valueOf(US_CYCLES))
            && elapsed < ideal + fromInteger(2 * valueOf(US_CYCLES)))
            $display("TEST_PASS sifs_response subtype=%0d cycles=%0d ideal=%0d", expectedSubtype, elapsed, ideal);
        else $display("TEST_FAIL sifs_response sent=%0d cycles=%0d ideal=%0d", sent, elapsed, ideal);
        $finish(0);
    endrule
endmodule
