import GetPut::*;
import ClientServer::*;
import Connectable::*;
import Vector::*;
import Types::*;
import MacCore::*;
import PhyCore::*;
import Arbitration::*;

`ifndef HIDDEN_WARM_US
`define HIDDEN_WARM_US 2000
`endif
`ifndef HIDDEN_MEASURE_US
`define HIDDEN_MEASURE_US 10000
`endif

// 与 ns3-hidden-reference.cc 共用的受控场景：16个真实MAC/PHY，0为汇点，
// 1..N为隐藏发送者。固定RSS矩阵用于排除距离ROM/默认控制功率的额外差异；
// 信道调度仍经过生产 Arbiter。这里不覆盖 DMA/配置桥，后者由 D/T/C 回归覆盖。
module mkTestHidden16(Empty);
    Vector#(NODE_NUM, MacCore) mac <- genWithM(compose(mkMacDCF, fromInteger));
    Vector#(NODE_NUM, PhyCore) phy <- genWithM(compose(mkPhyYansWifi, fromInteger));
    ArbiterIFC arb <- mkArbiter;
    Reg#(UInt#(64)) cycle <- mkReg(0);
    Reg#(UInt#(64)) origin <- mkReg(0);
    Reg#(UInt#(4)) senders <- mkReg(15);
    Reg#(Bool) rts <- mkReg(False);
    Reg#(Bool) longRun <- mkReg(False);
    Reg#(Bool) burstOnly <- mkReg(False);
    Reg#(Bool) running <- mkReg(False);
    Vector#(NODE_NUM, Reg#(UInt#(4))) cfgStep <- replicateM(mkReg(0));
    Vector#(NODE_NUM, Reg#(Bool)) cfgWaiting <- replicateM(mkReg(False));
    Vector#(NODE_NUM, Reg#(UInt#(32))) submitted <- replicateM(mkReg(0));
    Vector#(NODE_NUM, Reg#(UInt#(32))) completed <- replicateM(mkReg(0));
    Vector#(NODE_NUM, Reg#(Bit#(64))) lastSeen <- replicateM(mkReg('1));
    Vector#(NODE_NUM, Reg#(UInt#(32))) perSource <- replicateM(mkReg(0));
    Vector#(NODE_NUM, Reg#(Bool)) idle <- replicateM(mkReg(False));
    Vector#(NODE_NUM, Reg#(Bool)) airSeen <- replicateM(mkReg(False));
    Vector#(NODE_NUM, Reg#(UInt#(32))) lastAirStart <- replicateM(mkReg(0));
    Vector#(NODE_NUM, Reg#(UInt#(2))) probeStep <- replicateM(mkReg(0));
    Vector#(NODE_NUM, Reg#(Bool)) probeWaiting <- replicateM(mkReg(False));
    Reg#(UInt#(32)) uniqueRx <- mkReg(0);
    Reg#(UInt#(32)) totalUniqueRx <- mkReg(0);
    Reg#(UInt#(32)) duplicateRx <- mkReg(0);
    Reg#(Bool) reported <- mkReg(False);
    Reg#(UInt#(16)) idleStable <- mkReg(0);
    UInt#(64) factor = longRun ? 10 : 1;
    UInt#(64) warm = fromInteger(`HIDDEN_WARM_US * valueOf(US_CYCLES)) * factor;
    UInt#(64) endMeasure = fromInteger((`HIDDEN_WARM_US + `HIDDEN_MEASURE_US) * valueOf(US_CYCLES)) * factor;

    rule tick; cycle <= cycle + 1; endrule
    rule arguments(cycle == 1);
        let n1 <- $test$plusargs("n1"); let n2 <- $test$plusargs("n2");
        let n4 <- $test$plusargs("n4"); let n8 <- $test$plusargs("n8");
        // 固定两位编号，避免$test$plusargs按前缀把10..15误认成1。
        // 保留原四档参数；新的完整曲线使用+nodes01到+nodes15。
        let c01 <- $test$plusargs("nodes01"); let c02 <- $test$plusargs("nodes02");
        let c03 <- $test$plusargs("nodes03"); let c04 <- $test$plusargs("nodes04");
        let c05 <- $test$plusargs("nodes05"); let c06 <- $test$plusargs("nodes06");
        let c07 <- $test$plusargs("nodes07"); let c08 <- $test$plusargs("nodes08");
        let c09 <- $test$plusargs("nodes09"); let c10 <- $test$plusargs("nodes10");
        let c11 <- $test$plusargs("nodes11"); let c12 <- $test$plusargs("nodes12");
        let c13 <- $test$plusargs("nodes13"); let c14 <- $test$plusargs("nodes14");
        let c15 <- $test$plusargs("nodes15");
        let enabled <- $test$plusargs("rts"); let longer <- $test$plusargs("long");
        let burst <- $test$plusargs("burst");
`ifdef HIDDEN_FINITE_BURST
        burstOnly <= True;
`else
        burstOnly <= burst;
`endif
        senders <= c01 ? 1 : c02 ? 2 : c03 ? 3 : c04 ? 4 : c05 ? 5
                 : c06 ? 6 : c07 ? 7 : c08 ? 8 : c09 ? 9 : c10 ? 10
                 : c11 ? 11 : c12 ? 12 : c13 ? 13 : c14 ? 14 : c15 ? 15
                 : n1 ? 1 : n2 ? 2 : n4 ? 4 : n8 ? 8 : 15;
        rts <= enabled; longRun <= longer;
    endrule
    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        mkConnection(mac[i].lowMacTxClt, phy[i].lowMacTxSrv);
        mkConnection(phy[i].lowMacRxClt, mac[i].lowMacRxSrv);
        mkConnection(phy[i].phyTxClt, arb.phyRxMetaSrv[i]);
        rule status;
            let s <- phy[i].getPhyStatus.get;
            mac[i].phyStatus.put(s);
        endrule
        rule channel;
            let evt <- arb.phyTxMetaClt[i].request.get;
            // 峰值按空口开始点推进，元数据必须保持时间线顺序。
            if (evt.airTimeValid) begin
                if (airSeen[i] && evt.airStarted - lastAirStart[i] >= 'h80000000) begin
                    $display("TEST_FAIL hidden16 air_timeline node=%0d previous=%0d incoming=%0d", i, lastAirStart[i], evt.airStarted);
                    $finish(1);
                end
                lastAirStart[i] <= evt.airStarted; airSeen[i] <= True;
            end
            // ns-3: RSS -40/-110dBm，20MHz，290K，NF7dB。
            // 归一到本PHY的0dB噪声底，并量化到1/32dB；所有帧均用同一RSS矩阵。
            evt.rfParam.power = (i == 0 || evt.srcPhyId == 0) ? 1727 : -513;
            phy[i].phyRxSrv.request.put(evt);
            arb.phyTxMetaClt[i].response.put(GenericResp{});
        endrule
        rule rxHandshake; let ignored <- phy[i].phyRxSrv.response.get; endrule
        rule configure(cycle > 2 && cfgStep[i] < 4 && !cfgWaiting[i]);
            RegOffset offset = cfgStep[i] == 0 ? mac_cw_max_off
                             : cfgStep[i] == 1 ? mac_retry_limit_off
                             : cfgStep[i] == 2 ? mac_rts_thresh_off : mac_timeout_off;
            Bit#(32) value = cfgStep[i] == 0 ? 10 : cfgStep[i] == 1 ? 6
                          : cfgStep[i] == 2 ? (rts ? 100 : 65535) : 45;
            mac[i].macRegSrv.request.put(RegAccessReq{writeEnable: True, regOffset: offset, writeData: value});
            cfgWaiting[i] <= True;
        endrule
        rule configured(cfgWaiting[i]);
            let response <- mac[i].macRegSrv.response.get;
            if (response.error) begin $display("TEST_FAIL hidden16 config node=%0d", i); $finish(1); end
            cfgWaiting[i] <= False; cfgStep[i] <= cfgStep[i] + 1;
        endrule
        if (i != 0) begin
            rule inject(running && cycle - origin < endMeasure && fromInteger(i) <= senders
                && (!burstOnly || submitted[i] < 1)
                && (cycle - origin) % fromInteger(80 * valueOf(US_CYCLES)) == fromInteger(i * valueOf(US_CYCLES)));
                let packet = getEmptyMacEvent;
                packet.srcMacId = fromInteger(i); packet.dstMacId = 0;
                packet.rfParam = RfParam{power: 2000, mcs: 7};
                // 非QoS 802.11a: UDP1000+UDP8+IP20+LLC8+MAC24+FCS4。
                packet.mpduDigest.length = 1064;
                packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
                // RTS剩余交换: 3*SIFS + CTS44 + DATA180 + ACK44 = 316us。
                packet.mpduDigest.duration = rts ? 316 : 60;
                packet.mpduDigest.cacheAddr = zeroExtend(pack(submitted[i]));
                mac[i].highMacTxSrv.request.put(packet);
                submitted[i] <= submitted[i] + 1;
            endrule
        end
        rule complete;
            let ignored <- mac[i].highMacTxSrv.response.get;
            completed[i] <= completed[i] + 1;
        endrule
        rule probe(running && cycle - origin >= endMeasure && !probeWaiting[i]);
            mac[i].macRegSrv.request.put(RegAccessReq{writeEnable: False,
                regOffset: probeStep[i] == 0 ? mac_dcf_state_off : mac_fifoin_count_off, writeData: 0});
            probeWaiting[i] <= True;
        endrule
        rule probed(probeWaiting[i]);
            let response <- mac[i].macRegSrv.response.get;
            if (response.error) begin $display("TEST_FAIL hidden16 status node=%0d", i); $finish(1); end
            if (probeStep[i] == 0) begin
                idle[i] <= response.readData == zeroExtend(pack(DCF_IDLE));
                probeStep[i] <= 1;
            end else begin
                idle[i] <= idle[i] && response.readData == 0;
                probeStep[i] <= 0;
            end
            probeWaiting[i] <= False;
        endrule
    end
    rule start(!running);
        Bool ready = True;
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) ready = ready && cfgStep[i] == 4;
        if (ready) begin
            running <= True; origin <= cycle;
            $display("HIDDEN_CONFIG total_nodes=16 senders=%0d rts=%0d warm_us=%0d measure_us=%0d cw=15:1023 timeout_us=45 cycles_per_us=%0d burst=%0d",
                     senders, rts, fromInteger(`HIDDEN_WARM_US) * factor, fromInteger(`HIDDEN_MEASURE_US) * factor, valueOf(US_CYCLES), burstOnly);
        end
    endrule
    rule receive;
        let packet <- mac[0].highMacRxClt.request.get;
        mac[0].highMacRxClt.response.put(GenericResp{});
        let source = packet.srcMacId;
        if (source > 0 && source <= zeroExtend(pack(senders))) begin
            Bool duplicate = lastSeen[source] == packet.mpduDigest.cacheAddr;
            lastSeen[source] <= packet.mpduDigest.cacheAddr;
            if (!duplicate) totalUniqueRx <= totalUniqueRx + 1;
            if (running && cycle - origin >= warm && cycle - origin < endMeasure) begin
                if (duplicate) duplicateRx <= duplicateRx + 1;
                else begin
                    uniqueRx <= uniqueRx + 1;
                    perSource[source] <= perSource[source] + 1;
                end
            end
        end else begin $display("TEST_FAIL hidden16 unexpected source=%0d", source); $finish(1); end
    endrule
    rule report(running && cycle - origin >= endMeasure && !reported);
        $display("HIDDEN_RESULT senders=%0d rts=%0d unique=%0d duplicates=%0d measure_us=%0d",
                 senders, rts, uniqueRx, duplicateRx, fromInteger(`HIDDEN_MEASURE_US) * factor);
        reported <= True;
        for (Integer i = 1; i < valueOf(NODE_NUM); i = i + 1)
            $display("HIDDEN_SOURCE node=%0d submitted=%0d completed=%0d unique=%0d", i, submitted[i], completed[i], perSource[i]);
    endrule
    rule drain(reported);
        Bool empty = True;
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) empty = empty && idle[i];
        idleStable <= empty ? idleStable + 1 : 0;
        if (idleStable == fromInteger(100 * valueOf(US_CYCLES))) begin
            if (totalUniqueRx == 0) begin $display("TEST_FAIL hidden16 no delivery"); $finish(1); end
            $display("TEST_PASS hidden16 drained total_nodes=16 senders=%0d rts=%0d", senders, rts);
            $finish(0);
        end
    endrule
    rule watchdog(running && cycle - origin >= endMeasure + fromInteger(1000000 * valueOf(US_CYCLES)));
        $display("TEST_FAIL hidden16 drain timeout"); $finish(1);
    endrule
endmodule
