// ============================================================================
// TestBsvTop_hidden_v2.bsv - 隐藏节点拓扑饱和吞吐测试 (Bluesim, 含新碰撞模型)
//
// 对齐板测 test_hidden_terminal.c / ns-3 hidden-terminal.cc 口径:
// 拓扑: node0 = 中心汇点(仅收), node1..N = 外围发送点
//   - 外围 i <-> 中心 0: 距离 8   (可达, rx = 2000-578 = 1422 > CS 门限 128)
//   - 其余全对:          距离 1023 (互相隐藏, rx = 2000-1926 = 74 < 128)
//   => 外围节点互相看不见, 只会在中心处碰撞 (典型隐藏终端)
//
// MAC 参数 (同板测): MCS=7, 帧长 1038B(1000B payload 口径), CW[15,127],
//   retry=6, timeout=300(默认), SIFS16/Slot9/DIFS34, txPower=2000
// 发送: 每 1ms 每节点注入 1 包, 深度 10 队列自然背压 (尽力打满)
// 去重: cacheAddr 低 16 位作 seq, 按 (src,seq) 位图去重
//   => aggregate goodput = 去重后包数 * 1000B * 8 / 窗口
// 档位: RTS off (N=1,2,4,7) -> RTS on (N=1,2,4,7), 共 8 档
//   每档 20ms 统计窗 + 8ms 冷却(清队列/退避, 防跨档污染)
// 时标: 200 cycles/us
// ============================================================================

import GetPut::*;
import Connectable::*;
import ClientServer::*;
import BRAM::*;
import ROM::*;
import Vector::*;
import FIFOF::*;
import StmtFSM::*;
import FIFO::*;

import BusConversion::*;
import AxiStreamTypes::*;
import Types::*;
import MacCore::*;
import PhyCore::*;
import CsmaUtils::*;
import PrimUtils::*;
import Channel::*;
import Arbitration::*;
import MacBridge::*;
import CfgBridge::*;
import BsvTov_simple::*;
import Axi4LiteTypes::*;
import CfgAxiLite::*;

typedef 8 TEST_NODE_NUM;

// ---- 测试参数 (对齐板测 test_hidden_terminal.c) ----
Integer  pktLen    = 1038;   // 空口帧长 (1000B payload 口径)
Integer  payloadB  = 1000;   // goodput 换算字节
Int#(12) txPower   = fromInteger(2000);  // 62.5dBm, 同板测 CFG_TXPOWER
Bit#(32) rtsThOff  = 65535;  // 恒不触发 RTS
Bit#(32) rtsThOn   = 100;    // 1038 > 100 触发 RTS
Bit#(32) cwMinExp  = 4;      // CWmin = 2^4-1 = 15
Bit#(32) cwMaxExp  = 7;      // CWmax = 2^7-1 = 127
Bit#(32) retryLim  = 6;      // FrameRetryLimit
Integer  nStages   = 8;      // off{1,2,4,7} + on{1,2,4,7}
Integer  sendDeltaUs = 1000; // 每节点注入间隔 (us)
Integer  stageUs   = 20000;  // 每档统计窗 (us)
Integer  coolUs    = 8000;   // 档间冷却 (us)

// 距离: d=8 -> loss=578 -> rx=1422 (过 CS 门限)
//        d=1023 -> loss=1926 -> rx=74 (不过 CS 门限, 真隐藏)
function UInt#(4) activeSendersOf(Int#(32) s);
    Int#(32) k = (s < 4) ? s : s - 4;
    return (k == 0) ? 1 : (k == 1) ? 2 : (k == 2) ? 4 : 7;
endfunction

// MAC 配置条目: 节点 0..7 x {cwMin, cwMax, retry, rtsTh} = 32 笔
// i[4:3]=reg, i[2:0]=node; 初始 rtsTh=off
function Tuple2#(Bit#(32), Bit#(32)) initCfgEntry(UInt#(6) i);
    Bit#(6) ib = pack(i);
    Bit#(3) node = ib[2:0];
    Bit#(2) r = ib[4:3];
    Bit#(32) off = (r == 0) ? mac_cw_min_off
                 : (r == 1) ? mac_cw_max_off
                 : (r == 2) ? mac_retry_limit_off
                 : mac_rts_thresh_off;
    Bit#(32) val = (r == 0) ? cwMinExp
                 : (r == 1) ? cwMaxExp
                 : (r == 2) ? retryLim
                 : rtsThOff;
    return tuple2(node_base_addr + node_per_node * zeroExtend({1'b0, node}) + off, val);
endfunction

typedef enum {
    PH_PER,     // PER 表初始化 (全通过, 对齐 ns-3 理想信道)
    PH_TOPO,    // 拓扑距离配置
    PH_CFG0,    // 初始 MAC 配置: 发起写
    PH_CFG1,    // 等 awReady/wReady
    PH_CFG2,    // 等 bValid
    PH_RTS0,    // stage 4 前: 重写 rtsTh=on
    PH_RTS1,
    PH_RTS2,
    PH_COOL,    // 档间冷却
    PH_RUN,     // 运行/打点/换档
    PH_DONE
} TestPhase deriving (Eq, Bits);

module mkTestRawEmuCore_hidden_v2(Empty);
    let core <- mkEmuCore;

    // ---- AXI-Lite 从接口驱动 ----
    Reg#(Bool) arValid <- mkReg(False);
    Reg#(Bit#(AXI_ADDR_WIDTH)) arAddr <- mkReg(0);
    Reg#(Bool) rReady <- mkReg(False);
    Reg#(Bool) awValid <- mkReg(False);
    Reg#(Bit#(AXI_ADDR_WIDTH)) awAddr <- mkReg(0);
    Reg#(Bool) wValid <- mkReg(False);
    Reg#(Bit#(AXI_DATA_WIDTH)) wData <- mkReg(0);
    Reg#(Bit#(TDiv#(AXI_DATA_WIDTH, BYTE_WIDTH))) wStrb <- mkReg(0);
    Reg#(Bool) bReady <- mkReg(False);

    rule driveWriteAddrChannel;
        core.dmaAxiLiteSlave.wrSlave.awValidData(awValid, awAddr, 0);
    endrule
    rule driveWriteDataChannel;
        core.dmaAxiLiteSlave.wrSlave.wValidData(wValid, wData, wStrb);
    endrule
    rule driveWriteRespChannel;
        core.dmaAxiLiteSlave.wrSlave.bReady(bReady);
    endrule
    rule driveReadAddrChannel;
        core.dmaAxiLiteSlave.rdSlave.arValidData(arValid, arAddr, 0);
    endrule
    rule driveReadDataChannel;
        core.dmaAxiLiteSlave.rdSlave.rReady(rReady);
    endrule

    // ---- 公共状态 ----
    Reg#(UInt#(64)) cycleCount <- mkReg(0);
    Reg#(UInt#(32)) initIdx <- mkReg(0);
    Reg#(File) logFile <- mkReg(InvalidFile);

    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    rule openLog (cycleCount == 10);
        let fd <- $fopen("/home/gtx/dev/RealEmu/scripts/hidden_v2.txt", "w");
        logFile <= fd;
    endrule

    // ---- 阶段/档位 ----
    Reg#(TestPhase) phase <- mkReg(PH_PER);
    Reg#(int) stage <- mkReg(0);
    Reg#(UInt#(6)) cfgIdx <- mkReg(0);
    Reg#(UInt#(7)) topoIdx <- mkReg(0);
    Reg#(UInt#(64)) stageEndCycle <- mkReg(0);

    // ---- 接收: (src, seq) 位图去重 ----
    // 每源 65536 seq -> 8KB 位图, Bluesim 可承受; 只记节点 1..7
    Vector#(8, Reg#(Bit#(16))) lastSeq <- replicateM(mkReg(0));
    Vector#(8, Reg#(Bit#(16))) txSeq <- replicateM(mkReg(0));  // 发送端每节点 seq
    Reg#(UInt#(32)) stageRecv <- mkReg(0);   // 本档去重后收包数
    Reg#(UInt#(32)) stageRaw  <- mkReg(0);   // 本档裸收包数(含重传重复)
    Reg#(UInt#(64)) recvTotal <- mkReg(0);   // 累计去重收包数
    Reg#(UInt#(32)) dupTotal  <- mkReg(0);   // 累计重复帧数

    // 简化去重: 收包 seq 必须严格递增才算新 (发送端 seq 递增, 重传帧 seq 旧)
    // 重复 = sq <= lastSeq[src]. 重传帧 sq 旧, 判为重复
    rule receive;
        let rxpkt <- core.rx.get;
        MacEvent rxReq = unpack(truncate(rxpkt.tData));
        if (rxReq.srcMacId >= 1 && rxReq.srcMacId < fromInteger(valueOf(TEST_NODE_NUM))) begin
            UInt#(3) s = truncate(unpack(rxReq.srcMacId));
            Bit#(16) sq = truncate(rxReq.mpduDigest.cacheAddr);
            stageRaw <= stageRaw + 1;
            if (sq > lastSeq[s]) begin
                lastSeq[s] <= sq;
                stageRecv <= stageRecv + 1;
                recvTotal <= recvTotal + 1;
            end else begin
                dupTotal <= dupTotal + 1;
            end
            if (logFile != InvalidFile)
                $fwrite(logFile, "RX %0d %0d %0d %0d\n",
                        $time, rxReq.srcMacId, sq, cycleCount);
        end
    endrule

    (* descending_urgency = "receive, controller" *)
    rule controller;
        case (phase)
        // ---------- PER 表初始化 ----------
        PH_PER: begin
            if (cycleCount % 10 == 1) begin
                if (initIdx < 16383) begin
                    let percfg = getEmptyPerCfg;
                    percfg.perIn = truncate(initIdx);
                    percfg.perOut = 'hFFFF;
                    let bridgeTag = getEmptyBridgeTag();
                    bridgeTag.control = 1;
                    bridgeTag.notUsed = 1;
                    AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
                        tData: zeroExtend(pack(tuple2(percfg, bridgeTag))),
                        tKeep: '1,
                        tLast: True,
                        tUser: 0
                    };
                    core.tx.put(axiPkt);
                    initIdx <= initIdx + 1;
                end else begin
                    $display("[HT] PER table initialized: 16383 entries all-pass");
                    initIdx <= 0;
                    phase <= PH_TOPO;
                end
            end
        end

        // ---------- 拓扑: 0<->i 距离 8, 其余 1023 ----------
        PH_TOPO: begin
            if (cycleCount % 10 == 1) begin
                // topoIdx = src*8+dst 枚举 64 个有序对, 跳过 src==dst
                if (topoIdx < fromInteger(64)) begin
                    // topoIdx = src*8+dst 枚举全部有序对, 跳过 src==dst
                    Bit#(3) s3 = truncate(pack(topoIdx)[5:3]);
                    Bit#(3) d3 = truncate(pack(topoIdx)[2:0]);
                    if (s3 != d3) begin
                        let chancfg = getEmptyChannelCfg;
                        chancfg.srcPhyId = zeroExtend(s3);
                        chancfg.dstPhyId = zeroExtend(d3);
                        // 中心 0 <-> 外围 i: 距离 8; 外围互对: 1023
                        chancfg.distance = ((s3 == 0) || (d3 == 0)) ? 8 : 1023;
                        let bridgeTag = getEmptyBridgeTag();
                        bridgeTag.control = 1;
                        AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
                            tData: zeroExtend(pack(tuple2(chancfg, bridgeTag))),
                            tKeep: '1,
                            tLast: True,
                            tUser: 0
                        };
                        core.tx.put(axiPkt);
                    end
                    topoIdx <= topoIdx + 1;
                end else if (topoIdx == fromInteger(64)) begin
                    $display("[HT] topology set: center=0, 0<->ext d=8, ext<->ext d=1023");
                    topoIdx <= 0;
                    phase <= PH_CFG0;
                end
            end
        end

        // ---------- 初始 MAC 配置 32 笔 ----------
        PH_CFG0: begin
            match {.a, .d} = initCfgEntry(cfgIdx);
            awAddr <= a; wData <= d; wStrb <= '1;
            awValid <= True; wValid <= True;
            phase <= PH_CFG1;
        end
        PH_CFG1: begin
            if (core.dmaAxiLiteSlave.wrSlave.awReady &&
                core.dmaAxiLiteSlave.wrSlave.wReady) begin
                awValid <= False; wValid <= False; bReady <= True;
                phase <= PH_CFG2;
            end
        end
        PH_CFG2: begin
            if (core.dmaAxiLiteSlave.wrSlave.bValid) begin
                bReady <= False;
                if (cfgIdx + 1 == 32) begin
                    cfgIdx <= 0;
                    $display("[HT] cfg done: cwExp[%0d,%0d] retry=%0d rtsTh=off",
                             cwMinExp, cwMaxExp, retryLim);
                    stageEndCycle <= cycleCount + fromInteger(stageUs * 200);
                    stage <= 0;
                    phase <= PH_RUN;
                end else begin
                    cfgIdx <= cfgIdx + 1;
                    phase <= PH_CFG0;
                end
            end
        end

        // ---------- stage 4 前: 8 节点重写 rtsTh=on ----------
        PH_RTS0: begin
            awAddr <= node_base_addr + node_per_node * zeroExtend({1'b0, pack(cfgIdx)[2:0]}) + mac_rts_thresh_off;
            wData <= rtsThOn; wStrb <= '1;
            awValid <= True; wValid <= True;
            phase <= PH_RTS1;
        end
        PH_RTS1: begin
            if (core.dmaAxiLiteSlave.wrSlave.awReady &&
                core.dmaAxiLiteSlave.wrSlave.wReady) begin
                awValid <= False; wValid <= False; bReady <= True;
                phase <= PH_RTS2;
            end
        end
        PH_RTS2: begin
            if (core.dmaAxiLiteSlave.wrSlave.bValid) begin
                bReady <= False;
                if (cfgIdx + 1 == fromInteger(valueOf(TEST_NODE_NUM))) begin
                    cfgIdx <= 0;
                    $display("[HT] rtsThreshold switched to ON (%0d)", rtsThOn);
                    stageEndCycle <= cycleCount + fromInteger(stageUs * 200);
                    phase <= PH_RUN;
                end else begin
                    cfgIdx <= cfgIdx + 1;
                    phase <= PH_RTS0;
                end
            end
        end

        // ---------- 档间冷却 ----------
        PH_COOL: begin
            if (cycleCount >= stageEndCycle) begin
                stageEndCycle <= cycleCount + fromInteger(stageUs * 200);
                phase <= PH_RUN;
            end
        end

        // ---------- 运行: 发包 + 到点打点换档 ----------
        PH_RUN: begin
            // 发送: 节点 1..7, 每 1ms 错开 1us
            for (Integer n = 1; n < valueOf(TEST_NODE_NUM); n = n + 1) begin
                if (fromInteger(n) <= activeSendersOf(stage)
                    && cycleCount % fromInteger(sendDeltaUs * 200) == fromInteger(n)) begin
                    let txReq = getEmptyMacEvent;
                    txReq.srcMacId = fromInteger(n);
                    txReq.dstMacId = 0;
                    txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
                    txReq.mpduDigest.length = fromInteger(pktLen);
                    txReq.rfParam.power = txPower;
                    txReq.rfParam.mcs = 7;
                    txReq.mpduDigest.duration = 0;                    // 同板测
                    txReq.mpduDigest.cacheAddr = zeroExtend(txSeq[n]);  // seq 递增
                    txSeq[n] <= txSeq[n] + 1;
                    let bridgeTag = getEmptyBridgeTag();
                    AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
                        tData: zeroExtend(pack(tuple2(txReq, bridgeTag))),
                        tKeep: '1,
                        tLast: True,
                        tUser: 0
                    };
                    core.tx.put(axiPkt);
                end
            end
            if (cycleCount >= stageEndCycle) begin
                // goodput = N_unique * 1000B * 8 / 20000us -> Mbps = N*0.4
                UInt#(64) thrX100 = zeroExtend(stageRecv) * 40;
                $display("[HT] stage=%0d rts=%0d senders=%0d recvUnique=%0d raw=%0d dupTot=%0d thr=%0d.%02d Mbps",
                         stage, (stage >= 4) ? 1 : 0, activeSendersOf(stage),
                         stageRecv, stageRaw, dupTotal, thrX100 / 100, thrX100 % 100);
                if (logFile != InvalidFile)
                    $fwrite(logFile, "STAGE %0d %0d %0d %0d %0d %0d\n",
                            stage, (stage >= 4) ? 1 : 0, activeSendersOf(stage),
                            stageRecv, stageRaw, dupTotal);
                stageRecv <= 0;
                stageRaw <= 0;
                if (stage + 1 == fromInteger(nStages)) begin
                    phase <= PH_DONE;
                end else begin
                    stage <= stage + 1;
                    stageEndCycle <= cycleCount + fromInteger(coolUs * 200);
                    if (stage == 3) begin
                        cfgIdx <= 0;
                        phase <= PH_RTS0;    // stage 3 结束: 切 RTS on, 无冷却
                    end else begin
                        phase <= PH_COOL;
                    end
                end
            end
        end

        PH_DONE: begin
            $display("[HT] all %0d stages done, unique=%0d dup=%0d", nStages, recvTotal, dupTotal);
            $finish();
        end
        endcase
    endrule

endmodule
