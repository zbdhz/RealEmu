import GetPut::*;
import ClientServer::*;
import Vector::*;
import Types::*;
import PhyCore::*;
import Arbitration::*;

// 整包峰值边界必须以空口时间为准，同时覆盖真实仲裁/广播延迟。
// 三个目标包：尾前100周期重叠、尾前1周期重叠、恰在包尾开始。
// 前两包应失败，第三包应成功；默认PER表在本用例的SINR端点为0/FFFF。
module mkTestArbiterTailInterference(Empty);
    PhyCore phy <- mkPhyYansWifi(0);
    ArbiterIFC arb <- mkArbiter;
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(Bit#(3)) received <- mkReg(0);
    rule tick; cycle <= cycle + 1; endrule
    function PhyEvent frame(PhyId source, Bit#(64) cookie);
        let p = getEmptyPhyEvent;
        p.srcPhyId = source; p.dstPhyId = 0;
        p.rfParam = RfParam{power: 1000, mcs: 7};
        p.ppduLen = 1064; p.mpduDigest.length = 1064;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        p.mpduDigest.cacheAddr = cookie;
        p.airTimeValid = True; p.airStarted = cycle;
        return p;
    endfunction
    for (Integer trial = 0; trial < 3; trial = trial + 1) begin
        Integer startCycle = 1000 + trial * 500 * valueOf(US_CYCLES);
        Integer lead = trial == 0 ? 100 : trial == 1 ? 1 : 0;
        rule desired(cycle == fromInteger(startCycle));
            arb.phyRxMetaSrv[1].request.put(frame(1, fromInteger(trial)));
        endrule
        rule interfering(cycle == fromInteger(startCycle + 180 * valueOf(US_CYCLES) - lead));
            arb.phyRxMetaSrv[2].request.put(frame(2, fromInteger(32 + trial)));
        endrule
    end
    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        rule txResponse; let ignored <- arb.phyRxMetaSrv[i].response.get; endrule
        rule broadcast;
            let p <- arb.phyTxMetaClt[i].request.get;
            arb.phyTxMetaClt[i].response.put(GenericResp{});
            if (i == 0) begin
                phy.phyRxSrv.request.put(p);
                $display("TAIL_META cookie=%0d air=%0d delivered=%0d", p.mpduDigest.cacheAddr, p.airStarted, cycle);
            end
        endrule
    end
    rule rxResponse; let ignored <- phy.phyRxSrv.response.get; endrule
    rule receive;
        let p <- phy.lowMacRxClt.request.get;
        phy.lowMacRxClt.response.put(GenericResp{});
        if (p.mpduDigest.cacheAddr < 3) begin
            Bit#(2) index = truncate(p.mpduDigest.cacheAddr);
            received <= received | (3'b001 << index);
            $display("TAIL_RECEIVED cookie=%0d cycle=%0d", p.mpduDigest.cacheAddr, cycle);
        end
    endrule
    rule finish(cycle == fromInteger(1000 + 1500 * valueOf(US_CYCLES)));
        if (received == 3'b100)
            $display("TEST_PASS arbiter_tail_interference received=%b expected=100", received);
        else
            $display("TEST_FAIL arbiter_tail_interference received=%b expected=100", received);
        $finish(received == 3'b100 ? 0 : 1);
    endrule
endmodule
