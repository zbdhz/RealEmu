import GetPut::*;
import ClientServer::*;
import Vector::*;
import Types::*;
import PhyCore::*;

// 两个PHY具有相同的随机流和相同输入，只有输出背压不同。
// 每轮先用必过的两个包填满被测FIFO，再给第三包50%成功率。
// 一个包只能抽一次：有/无背压得到的成功包集合必须一致。
module mkTestPacketRandomRetention(Empty);
    Vector#(2, PhyCore) phy <- genWithM(compose(mkPhyYansWifi, fromInteger));
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Vector#(2, Reg#(Bit#(64))) received <- replicateM(mkReg(0));
    Reg#(UInt#(5)) midpointReceived <- mkReg(0);
    UInt#(32) period = fromInteger(1000 * valueOf(US_CYCLES));
    UInt#(32) position = cycle % period;
    UInt#(32) trial = cycle / period;
    rule tick; cycle <= cycle + 1; endrule
    rule tableValue(trial < 16 && (position == 0 || position == fromInteger(430 * valueOf(US_CYCLES))));
        for (Integer i = 0; i < 2; i = i + 1)
            phy[i].perSrv.request.put(PerCfg{perIn: 8959, perOut: position == 0 ? 'hffff : 'h8000});
    endrule
    rule send(trial < 16 && (position == fromInteger(10 * valueOf(US_CYCLES))
        || position == fromInteger(230 * valueOf(US_CYCLES))
        || position == fromInteger(450 * valueOf(US_CYCLES))));
        let p = getEmptyPhyEvent;
        p.srcPhyId = 2; p.dstPhyId = 3;
        p.rfParam = RfParam{power: 1000, mcs: 7};
        p.ppduLen = 1064; p.mpduDigest.length = 1064;
        p.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        UInt#(32) index = trial * 3 + (position == fromInteger(10 * valueOf(US_CYCLES)) ? 0
                        : position == fromInteger(230 * valueOf(US_CYCLES)) ? 1 : 2);
        p.mpduDigest.cacheAddr = zeroExtend(pack(index));
        for (Integer i = 0; i < 2; i = i + 1) phy[i].phyRxSrv.request.put(p);
    endrule
    for (Integer i = 0; i < 2; i = i + 1) begin
        rule cfgResponse; let ignored <- phy[i].perSrv.response.get; endrule
        rule rxResponse; let ignored <- phy[i].phyRxSrv.response.get; endrule
        rule receive(i == 0 || position >= fromInteger(850 * valueOf(US_CYCLES)));
            let p <- phy[i].lowMacRxClt.request.get;
            phy[i].lowMacRxClt.response.put(GenericResp{});
            Bit#(6) cookie = truncate(p.mpduDigest.cacheAddr);
            received[i] <= received[i] | (1 << cookie);
            UInt#(6) number = unpack(cookie);
            if (i == 0 && number % 3 == 2) midpointReceived <= midpointReceived + 1;
        endrule
    end
    rule finish(cycle == 16 * period);
        if (received[0] == received[1] && midpointReceived > 0 && midpointReceived < 16)
            $display("TEST_PASS packet_random_retention midpoint=%0d reference=%h blocked=%h", midpointReceived, received[0], received[1]);
        else $display("TEST_FAIL packet_random_retention midpoint=%0d reference=%h blocked=%h", midpointReceived, received[0], received[1]);
        $finish(0);
    endrule
endmodule
