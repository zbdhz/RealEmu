import GetPut::*;
import ClientServer::*;
import Connectable::*;
import Types::*;
import MacCore::*;
import PhyCore::*;

// NAV有效期内不应发CTS；预约过期后仍须能响应新的正常RTS。
// 验证CTS的准入条件，与已承诺应答的SIFS不重新竞争CCA是两个不同问题。
module mkTestCtsNavReservation(Empty);
    MacCore mac <- mkMacDCF(0);
    PhyCore phy <- mkPhyYansWifi(0);
    mkConnection(mac.lowMacTxClt, phy.lowMacTxSrv);
    mkConnection(phy.lowMacRxClt, mac.lowMacRxSrv);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(4)) early <- mkReg(0);
    Reg#(UInt#(4)) late <- mkReg(0);
    rule tick; cycle <= cycle + 1; endrule
    rule status;
        let s <- phy.getPhyStatus.get;
        mac.phyStatus.put(s);
    endrule
    rule acceptedRx; let ignored <- phy.phyRxSrv.response.get; endrule
    rule reserve(cycle == 100);
        let p = getEmptyPhyEvent;
        p.srcPhyId = 2; p.dstPhyId = 3;
        p.rfParam = RfParam{power: 1000, mcs: 0};
        p.ppduLen = 14; p.mpduDigest.length = 14;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
        p.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_CTS));
        p.mpduDigest.duration = 600;
        phy.phyRxSrv.request.put(p);
    endrule
    for (Integer attempt = 0; attempt < 2; attempt = attempt + 1) begin
        Integer atUs = attempt == 0 ? 100 : 800;
        rule requestCts(cycle == fromInteger(atUs * valueOf(US_CYCLES)));
            let p = getEmptyPhyEvent;
            p.srcPhyId = 1; p.dstPhyId = 0;
            p.rfParam = RfParam{power: 1000, mcs: 0};
            p.ppduLen = 20; p.mpduDigest.length = 20;
            p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
            p.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_RTS));
            p.mpduDigest.duration = 316;
            phy.phyRxSrv.request.put(p);
        endrule
    end
    rule response;
        let p <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
        if (p.mpduDigest.frameSubType == fromInteger(valueOf(FC_CTRLSUB_CTS))) begin
            if (cycle < fromInteger(600 * valueOf(US_CYCLES))) early <= early + 1;
            else if (cycle >= fromInteger(800 * valueOf(US_CYCLES))) late <= late + 1;
            $display("CTS_NAV_RESPONSE cycle=%0d destination=%0d", cycle, p.dstPhyId);
        end
    endrule
    rule finish(cycle == fromInteger(1000 * valueOf(US_CYCLES)));
        if (early == 0 && late == 1)
            $display("TEST_PASS cts_nav_reservation early=%0d late=%0d", early, late);
        else
            $display("TEST_FAIL cts_nav_reservation early=%0d late=%0d expected=0,1", early, late);
        $finish(early == 0 && late == 1 ? 0 : 1);
    endrule
endmodule
