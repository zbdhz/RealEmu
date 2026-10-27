import GetPut::*;
import ClientServer::*;
import StmtFSM::*;
import Types::*;
import PhyCore::*;

// 独立的阶跃 PRR 表：MCS7 的 SINR>=20dB 必过，否则必败。
// 固定结果用于证明功率聚合和生命周期，不依赖随机抽样碰巧通过。
module mkTestPhyPeakInterference(Empty);
    PhyCore phy <- mkPhyYansWifi(0);
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(32)) origin <- mkReg(0);
    Reg#(UInt#(12)) entry <- mkReg(0);
    Reg#(Bit#(64)) received <- mkReg(0);
    Reg#(UInt#(8)) arrivals <- mkReg(0);
    Reg#(UInt#(2)) boundaryMode <- mkReg(0);
    rule tick; cycle <= cycle + 1; endrule
    rule acceptResponse;
        let ignored <- phy.phyRxSrv.response.get;
    endrule
    rule receive;
        let packet <- phy.lowMacRxClt.request.get;
        phy.lowMacRxClt.response.put(GenericResp{});
        Bit#(6) cookie = truncate(packet.mpduDigest.cacheAddr);
        received <= received | (1 << cookie);
        arrivals <= arrivals + 1;
    endrule
    function Action send(PhyId source, PowerDb power, Bit#(6) cookie, UInt#(16) length);
        return action
            let packet = getEmptyPhyEvent;
            packet.srcPhyId = source; packet.dstPhyId = 0;
            packet.rfParam = RfParam{power: power, mcs: 7};
            packet.ppduLen = pack(length);
            packet.mpduDigest.length = pack(length);
            packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
            packet.mpduDigest.cacheAddr = zeroExtend(cookie);
            phy.phyRxSrv.request.put(packet);
        endaction;
    endfunction
    function Stmt atUs(Integer microseconds);
        return seq await(cycle >= origin + fromInteger(microseconds * valueOf(US_CYCLES))); endseq;
    endfunction
    // 用独立规则精确命中周期；StmtFSM的await到下一action本身会增加周期。
    rule boundaryInterference(boundaryMode != 0 && cycle == origin
        + fromInteger(180 * valueOf(US_CYCLES)) - (boundaryMode == 1 ? 1 : 0));
        send(2, 640, boundaryMode == 1 ? 25 : 26, 14);
        boundaryMode <= 0;
    endrule
    Stmt test = seq
        for (entry <= 0; entry < 1120; entry <= entry + 1) seq
            action phy.perSrv.request.put(PerCfg{
                perIn: 7840 + zeroExtend(entry), perOut: entry >= 800 ? 'hffff : 0}); endaction
            action let ignored <- phy.perSrv.response.get; endaction
        endseq
        // A被B碰撞，C开始时A已结束但B还在：C必须受到B的尾部干扰。
        action origin <= cycle; send(1, 960, 0, 1064); endaction
        atUs(100); send(2, 960, 1, 1064);
        atUs(200); send(3, 960, 2, 1064);
        atUs(600);
        // 一个过CCA门限的弱干扰：SINR约21.36dB，应通过，证明没有强重叠硬否决。
        action origin <= cycle; send(1, 960, 3, 1064); endaction
        atUs(30); send(2, 256, 20, 14);
        atUs(600);
        // 两个同时存在的干扰：SINR约18.67dB，应失败。
        action origin <= cycle; send(1, 960, 4, 1064); endaction
        atUs(30); send(2, 256, 21, 14);
        atUs(35); send(3, 256, 22, 14);
        atUs(600);
        // 相同功率但不同时存在，不能跨时间相加：仍应通过。
        action origin <= cycle; send(1, 960, 5, 1064); endaction
        atUs(30); send(2, 256, 23, 14);
        atUs(80); send(3, 256, 24, 14);
        atUs(600);
        // 最后一个空口周期才到达：元数据虽稍后返回，也必须纳入整包最大值。
        action origin <= cycle; boundaryMode <= 1; send(1, 960, 6, 1064); endaction
        atUs(600);
        // 恰好在结束边界开始的帧不应回溯污染前一包，[start,end)。
        action origin <= cycle; boundaryMode <= 2; send(1, 960, 7, 1064); endaction
        atUs(600);
        // 下一包无干扰，不能继承前包峰值。
        action origin <= cycle; send(1, 960, 8, 1064); endaction
        atUs(600);
        // 隐藏弱帧先到，未触发SYNC/CCA；其存续区间仍必须影响稍后到达的目标帧。
        action origin <= cycle; send(2, 96, 27, 1064); endaction
        atUs(20); send(1, 768, 9, 1064);
        atUs(600);
        action
            Bit#(10) expected = (1 << 3) | (1 << 5) | (1 << 7) | (1 << 8);
            Bit#(10) observed = truncate(received);
            if (observed != expected) begin
                $display("TEST_FAIL peak_interference got=%h expected=%h", observed, expected);
                $finish(1);
            end
            $display("TEST_PASS peak_interference tail aggregate disjoint late boundary reset bitmap=%h", received);
            $finish(0);
        endaction
    endseq;
    mkAutoFSM(test);
    rule watchdog(cycle == fromInteger(10000 * valueOf(US_CYCLES)));
        $display("TEST_FAIL peak_interference watchdog"); $finish(1);
    endrule
endmodule
