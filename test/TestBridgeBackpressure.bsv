import Vector::*;
import GetPut::*;
import ClientServer::*;
import FIFOF::*;
import Types::*;
import MacBridge::*;
import CfgBridge::*;
import Arbitration::*;

module mkTestMacBridgeBackpressure(Empty);
    MacBridgeIFC bridge <- mkMacBridge;
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(7)) queued <- mkReg(0);
    Reg#(UInt#(7)) downloaded <- mkReg(0);
    Reg#(UInt#(7)) uploaded <- mkReg(0);
    Reg#(Bit#(64)) seenUp <- mkReg(0);
    Vector#(NODE_NUM, Reg#(Bit#(64))) seenDown <- replicateM(mkReg(0));
    Vector#(NODE_NUM, Reg#(UInt#(3))) sentUp <- replicateM(mkReg(0));
    rule tick; cycle <= cycle + 1; endrule
    rule sendDown(queued < 50);
        let packet = getEmptyMacEvent;
        packet.srcMacId = zeroExtend(pack(queued % 16));
        packet.dstMacId = 1;
        packet.mpduDigest.cacheAddr = zeroExtend(pack(queued));
        bridge.pcieTxSrv.request.put(packet);
        queued <= queued + 1;
    endrule
    rule downResponse; let r <- bridge.pcieTxSrv.response.get; endrule
    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        rule receiveDown(cycle >= 200);
            let packet <- bridge.macTxClt[i].request.get;
            bridge.macTxClt[i].response.put(GenericResp{});
            Bit#(6) id = truncate(packet.mpduDigest.cacheAddr);
            if (packet.srcMacId != fromInteger(i) || seenDown[i][id] == 1) begin
                $display("TEST_FAIL macbridge duplicate/wrong destination"); $finish(1);
            end
            seenDown[i] <= seenDown[i] | (1 << id);
        endrule
        rule sendUp(sentUp[i] < 4);
            let packet = getEmptyMacEvent;
            packet.srcMacId = fromInteger(i);
            packet.mpduDigest.cacheAddr = fromInteger(i * 4) + zeroExtend(pack(sentUp[i]));
            bridge.macRxSrv[i].request.put(packet);
            sentUp[i] <= sentUp[i] + 1;
        endrule
        rule upResponse; let r <- bridge.macRxSrv[i].response.get; endrule
    end
    rule receiveUp(cycle >= 200);
        let packet <- bridge.pcieRxClt.request.get;
        bridge.pcieRxClt.response.put(GenericResp{});
        Bit#(6) id = truncate(packet.mpduDigest.cacheAddr);
        if (seenUp[id] == 1 || zeroExtend(id >> 2) != packet.srcMacId) begin
            $display("TEST_FAIL macbridge duplicate/wrong upload"); $finish(1);
        end
        seenUp <= seenUp | (1 << id);
        uploaded <= uploaded + 1;
    endrule
    rule finish(cycle == 2000);
        Bit#(64) allDown = 0;
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) allDown = allDown | seenDown[i];
        if (queued == 50 && allDown == 'h3ffffffffffff && uploaded == 64 && seenUp == '1) begin
            $display("TEST_PASS macbridge_backpressure down=50 up=64"); $finish(0);
        end
        else begin $display("TEST_FAIL macbridge missing events up=%0d mask=%h", uploaded, allDown); $finish(1); end
    endrule
endmodule

module mkTestArbiterBackpressure(Empty);
    ArbiterIFC arb <- mkArbiter;
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Vector#(NODE_NUM, Reg#(UInt#(3))) sent <- replicateM(mkReg(0));
    Vector#(NODE_NUM, Reg#(Bit#(64))) received <- replicateM(mkReg(0));
    rule tick; cycle <= cycle + 1; endrule
    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        rule inject(sent[i] < 4);
            let packet = getEmptyPhyEvent;
            packet.srcPhyId = fromInteger(i);
            packet.mpduDigest.cacheAddr = fromInteger(i * 4) + zeroExtend(pack(sent[i]));
            arb.phyRxMetaSrv[i].request.put(packet);
            sent[i] <= sent[i] + 1;
        endrule
        rule ack; let r <- arb.phyRxMetaSrv[i].response.get; endrule
        rule receive(i != 15 || cycle >= 200);
            let packet <- arb.phyTxMetaClt[i].request.get;
            arb.phyTxMetaClt[i].response.put(GenericResp{});
            Bit#(6) id = truncate(packet.mpduDigest.cacheAddr);
            if (received[i][id] == 1 || packet.srcPhyId == fromInteger(i)
                || zeroExtend(id >> 2) != packet.srcPhyId) begin
                $display("TEST_FAIL arbiter duplicate/self/wrong event"); $finish(1);
            end
            received[i] <= received[i] | (1 << id);
        endrule
    end
    rule finish(cycle == 2000);
        Bool good = True;
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
            Bit#(64) expected = '1 ^ ('hf << (4 * i));
            good = good && received[i] == expected && sent[i] == 4;
        end
        if (good) begin $display("TEST_PASS arbiter_backpressure 64x15 events"); $finish(0); end
        else begin $display("TEST_FAIL arbiter missing broadcast events"); $finish(1); end
    endrule
endmodule

module mkTestCfgBridgeCompletion(Empty);
    CfgBridgeIFC bridge <- mkCfgBridge;
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(3)) perSent <- mkReg(0);
    Reg#(UInt#(3)) perCompleted <- mkReg(0);
    Reg#(UInt#(5)) chanSent <- mkReg(0);
    Reg#(UInt#(5)) chanCompleted <- mkReg(0);
    Vector#(NODE_NUM, Reg#(UInt#(3))) perSeen <- replicateM(mkReg(0));
    Vector#(NODE_NUM, Reg#(UInt#(3))) chanSeen <- replicateM(mkReg(0));
    Vector#(NODE_NUM, FIFOF#(Bool)) perAcks <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(Bool)) chanAcks <- replicateM(mkFIFOF);
    rule tick; cycle <= cycle + 1; endrule
    rule perInject(perSent < 3);
        bridge.perTxSrv.request.put(PerCfg{perIn: zeroExtend(perSent), perOut: zeroExtend(perSent) * 100});
        perSent <= perSent + 1;
    endrule
    rule channelInject(chanSent < 16);
        bridge.chanTxSrv.request.put(ChannelCfg{srcPhyId: 2, dstPhyId: zeroExtend(pack(chanSent)), distance: 8});
        chanSent <= chanSent + 1;
    endrule
    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        rule receivePer;
            let cfg <- bridge.perTxClt[i].request.get;
            if (cfg.perIn != zeroExtend(perSeen[i]) || cfg.perOut != zeroExtend(perSeen[i]) * 100) begin
                $display("TEST_FAIL cfg duplicate/lost/reordered PER"); $finish(1);
            end
            perSeen[i] <= perSeen[i] + 1;
            perAcks[i].enq(True);
        endrule
        rule completePer(i != 15 || cycle >= 300);
            perAcks[i].deq;
            bridge.perTxClt[i].response.put(GenericResp{});
        endrule
        rule receiveChannel;
            let cfg <- bridge.chanTxClt[i].request.get;
            if (cfg.dstPhyId != fromInteger(i) || cfg.srcPhyId != 2 || cfg.distance != 8) begin
                $display("TEST_FAIL cfg wrong channel target/fields"); $finish(1);
            end
            chanSeen[i] <= chanSeen[i] + 1;
            chanAcks[i].enq(True);
        endrule
        rule completeChannel(i != 15 || cycle >= 300);
            chanAcks[i].deq;
            bridge.chanTxClt[i].response.put(GenericResp{});
        endrule
    end
    rule perResponse;
        let r <- bridge.perTxSrv.response.get;
        if (cycle < 300) begin $display("TEST_FAIL PER acknowledged before node15 completed"); $finish(1); end
        perCompleted <= perCompleted + 1;
    endrule
    rule chanResponse;
        let r <- bridge.chanTxSrv.response.get;
        if (chanCompleted == 15 && cycle < 300) begin $display("TEST_FAIL channel acknowledged too early"); $finish(1); end
        chanCompleted <= chanCompleted + 1;
    endrule
    rule finish(cycle == 2000);
        Bool good = perCompleted == 3 && chanCompleted == 16;
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1)
            good = good && perSeen[i] == 3 && chanSeen[i] == 1;
        if (good) begin $display("TEST_PASS cfg_bridge_completion PER=3x16 channel=16"); $finish(0); end
        else begin $display("TEST_FAIL cfg missing completion per=%0d chan=%0d", perCompleted, chanCompleted); $finish(1); end
    endrule
endmodule
