import GetPut::*;
import ClientServer::*;
import Connectable::*;
import Types::*;
import MacCore::*;
import PhyCore::*;

// 查询从入队前一直持续到验收，必须仍能完成退避、TX、无ACK超时和队列排空。
// 与旧read-burst不同，本测试不靠“停止轮询后才恢复”通过。
module mkTestMacReadProgress(Empty);
    MacCore mac <- mkMacDCF(1);
    PhyCore phy <- mkPhyYansWifi(1);
    mkConnection(mac.lowMacTxClt, phy.lowMacTxSrv);
    mkConnection(phy.lowMacRxClt, mac.lowMacRxSrv);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(2)) phase <- mkReg(0);
    Reg#(Bool) cfgRetry <- mkReg(False);
    Reg#(Bool) queued <- mkReg(False);
    Reg#(UInt#(3)) forwarded <- mkReg(0);
    Reg#(UInt#(3)) ended <- mkReg(0);
    Reg#(UInt#(32)) reads <- mkReg(0);
    Reg#(Bit#(32)) lastFifo <- mkReg('1);
    rule tick; cycle <= cycle + 1; endrule
    rule status;
        let s <- phy.getPhyStatus.get;
        mac.phyStatus.put(s);
        if (s.txEnd) ended <= ended + 1;
    endrule
    rule configure(phase == 0);
        mac.macRegSrv.request.put(RegAccessReq{writeEnable: True,
            regOffset: cfgRetry ? mac_retry_limit_off : mac_rts_thresh_off,
            writeData: cfgRetry ? 0 : 65535});
        phase <= 1;
    endrule
    rule configured(phase == 1);
        let r <- mac.macRegSrv.response.get;
        if (r.error) begin $display("TEST_FAIL read_progress config"); $finish(1); end
        if (!cfgRetry) begin cfgRetry <= True; phase <= 0; end
        else phase <= 2;
    endrule
    rule inject(phase == 2 && !queued);
        let p = getEmptyMacEvent;
        p.srcMacId = 1; p.dstMacId = 0;
        p.rfParam = RfParam{power: 1000, mcs: 7};
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        p.mpduDigest.length = 1064;
        mac.highMacTxSrv.request.put(p);
        queued <= True;
    endrule
    rule query(phase == 2);
        mac.macRegSrv.request.put(RegAccessReq{writeEnable: False,
            regOffset: mac_fifoin_count_off, writeData: 0});
    endrule
    rule answer(phase == 2);
        let r <- mac.macRegSrv.response.get;
        if (r.error) begin $display("TEST_FAIL read_progress query"); $finish(1); end
        reads <= reads + 1; lastFifo <= r.readData;
    endrule
    rule channel;
        let p <- phy.phyTxClt.request.get;
        phy.phyTxClt.response.put(GenericResp{});
        forwarded <= forwarded + 1;
    endrule
    rule finish(cycle == fromInteger(2000 * valueOf(US_CYCLES)));
        if (queued && forwarded == 1 && ended == 1 && lastFifo == 0 && reads > 1000)
            $display("TEST_PASS mac_read_progress reads=%0d tx=%0d end=%0d fifo=%0d", reads, forwarded, ended, lastFifo);
        else $display("TEST_FAIL mac_read_progress reads=%0d tx=%0d end=%0d fifo=%0d", reads, forwarded, ended, lastFifo);
        $finish(0);
    endrule
endmodule
