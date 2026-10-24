// ============================================================================
// TestBsvTop_bianchi.bsv - Bianchi 饱和吞吐对照测试 (vs ns-3 wifi-bianchi.cc)
//
// 场景: 星型拓扑, 节点 1..activeSenders -> 节点 0, 每节点每 1ms 注入 1 包
//       (对应 ns-3 环形 adhoc nStas=2..7, pktInterval=1000us, 竞争流数相同)
// 档位: stage 0-5 = RTS off, senders 2..7
//       stage 6-11 = RTS on , senders 2..7
// 参数对齐 ns-3 (wifi-bianchi.cc 已修订): FrameRetryLimit=6,
//       CW[15,127] -> cwExp[4,7] (cwMin/cwMax 为指数, 2^4-1=15, 2^7-1=127),
//       SIFS16/Slot9(默认), timeout=300(RTL 默认; 70 会致 RTS/ACK 误超时)
// 帧口径: MPDU=1536B = 1500 payload + 24 MAC + 8 LLC/SNAP + 4 FCS
//       (ns-3 PacketSocketClient 直接发 1500B, 无 IP/UDP 头)
// 统计: 每 20ms 窗口收包数 N -> 应用吞吐 = N*1500*8/T (对照 ns-3 口径)
// 时标: US_CYCLES cycles/us（当前 250）
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

// ---- 测试参数 ----
Integer pktLen      = 1536;  // MPDU 长 (ns-3: 24 MAC + 8 LLC + 1500 payload + 4 FCS)
Int#(12) txPower    = fromInteger(1920);  // 60dBm, PER 全通过表下仅过 CCA 门限
Bit#(32) rtsThOff   = 65535;  // 恒不触发 RTS
Bit#(32) rtsThOn    = 100;    // length=1536 > 100 触发 RTS
Bit#(32) toVal      = 300;    // CTS/ACK timeout (us), 恢复 RTL 默认值; 70 会误超时
                                     // (RTS 后 SIFS16+CTS@MCS0~44+流水线 > 70, RTS 永远重传)
Bit#(32) cwMinExp   = 4;      // CWmin = 2^4 - 1 = 15
Bit#(32) cwMaxExp   = 7;      // CWmax = 2^7 - 1 = 127
Bit#(32) retryLim   = 6;      // ns-3 FrameRetryLimit = 6
Bit#(32) durRtsOn   = 384;    // RTS NAV = SIFS16+CTS44+SIFS16+DATA248+SIFS16+ACK44
Bit#(32) durRtsOff  = 56;     // (发送侧 NAV 值, DATA 帧实际 NAV 由 MAC 覆盖)
Integer nStages     = 12;     // off 2..7 + on 2..7
Integer sendDeltaUs = 1000;   // 每节点注入间隔 (us), 同 ns-3 pktInterval
Integer stageUs     = 20000;  // 每档统计窗 (us) = 20ms (Bluesim 运行时间限制)

function Bit#(32) nodeAddr(Integer node, Bit#(32) off);
    return node_base_addr + node_per_node * fromInteger(node) + off;
endfunction

// 初始配置: 8 节点 x {timeout, cwMin, cwMax, retry} 32 笔 + rtsTh(off) 8 笔 = 40 笔
// i[5]=0: reg=i[1:0], node=i[4:2]; i[5]=1: rtsTh, node=i[2:0]
function Tuple2#(Bit#(32), Bit#(32)) initCfgEntry(UInt#(6) i);
    Bit#(6) ib = pack(i);
    Bool isRts = (ib[5] == 1);
    Bit#(3) node = isRts ? ib[2:0] : {ib[4], ib[3], ib[2]};
    Bit#(2) r = ib[1:0];
    Bit#(32) off = isRts ? mac_rts_thresh_off
                 : (r == 0) ? mac_timeout_off
                 : (r == 1) ? mac_cw_min_off
                 : (r == 2) ? mac_cw_max_off
                 : mac_retry_limit_off;
    Bit#(32) val = isRts ? rtsThOff
                 : (r == 0) ? toVal
                 : (r == 1) ? cwMinExp
                 : (r == 2) ? cwMaxExp
                 : retryLim;
    return tuple2(node_base_addr + node_per_node * zeroExtend(node) + off, val);
endfunction

function UInt#(4) activeSendersOf(Int#(32) s);
    // stage 0..11 -> senders 2..7 (低 3 位即 s%6? 不对: s%6 != s&7)
    // 直接列查找表
    Int#(32) k = (s < 6) ? s : s - 6;
    return (k == 0) ? 2 : (k == 1) ? 3 : (k == 2) ? 4
         : (k == 3) ? 5 : (k == 4) ? 6 : 7;
endfunction

typedef enum {
    PH_PER,     // PER 表初始化 (全通过 0xFFFF, 对齐 ns-3 理想信道)
    PH_CFG0,    // 初始配置: 发起写
    PH_CFG1,    // 等 awReady/wReady
    PH_CFG2,    // 等 bValid
    PH_RTS0,    // stage 6 前: 重写 rtsTh=on, 发起
    PH_RTS1,
    PH_RTS2,
    PH_RUN,     // 运行/打点/换档
    PH_DONE
} TestPhase deriving (Eq, Bits);

module mkTestRawEmuCore_bianchi(Empty);
    let core <- mkEmuCore;

    // ---- AXI-Lite 从接口驱动 (每周期必须调用) ----
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
        let fd <- $fopen("bianchi_mcs7.txt", "w");
        logFile <= fd;
    endrule

    // ---- 档位/阶段 (controller 唯一写) ----
    Reg#(TestPhase) phase <- mkReg(PH_PER);
    Reg#(int) stage <- mkReg(0);
    Reg#(UInt#(6)) cfgIdx <- mkReg(0);
    Reg#(UInt#(64)) stageEndCycle <- mkReg(0);


    // ---- 接收: 只写统计, 不读 controller 寄存器 ----
    Reg#(UInt#(32)) stageRecv <- mkReg(0);   // 本档收包数
    Reg#(UInt#(64)) recvTotal <- mkReg(0);   // 累计收包数

    rule receive;
        let rxpkt <- core.rx.get;
        MacEvent rxReq = unpack(truncate(rxpkt.tData));
        recvTotal <= recvTotal + 1;
        if (phase == PH_RUN)
            stageRecv <= stageRecv + 1;
        if (logFile != InvalidFile)
            $fwrite(logFile, "RX %0d %0d %0d\n",
                    $time, rxReq.srcMacId, cycleCount);
    endrule

    // ---- controller ----
    (* descending_urgency = "receive, controller" *)
    rule controller;
        case (phase)
        // ---------- PER 表初始化: 灌 0xFFFF = 必 CRC OK ----------
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
                    $display("[BIANCHI] PER table initialized: 16383 entries all-pass");
                    phase <= PH_CFG0;
                end
            end
        end

        // ---------- 初始配置 40 笔 ----------
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
                if (cfgIdx + 1 == 40) begin
                    cfgIdx <= 0;
                    $display("[BIANCHI] cfg done: timeout=%0d cwExp[%0d,%0d] retry=%0d rtsTh=off",
                             toVal, cwMinExp, cwMaxExp, retryLim);
                    stageEndCycle <= cycleCount + fromInteger(stageUs * valueOf(US_CYCLES));
                    stage <= 0;
                    phase <= PH_RUN;
                end else begin
                    cfgIdx <= cfgIdx + 1;
                    phase <= PH_CFG0;
                end
            end
        end

        // ---------- stage 6 前: 8 节点重写 rtsTh=on ----------
        PH_RTS0: begin
            awAddr <= node_base_addr + node_per_node * zeroExtend(pack(cfgIdx)[2:0]) + mac_rts_thresh_off;
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
                    $display("[BIANCHI] rtsThreshold switched to ON (%0d)", rtsThOn);
                    stageEndCycle <= cycleCount + fromInteger(stageUs * valueOf(US_CYCLES));
                    phase <= PH_RUN;
                end else begin
                    cfgIdx <= cfgIdx + 1;
                    phase <= PH_RTS0;
                end
            end
        end

        // ---------- 运行: 发包 + 到点打点换档 ----------
        PH_RUN: begin
            // 发送: 节点 1..7, 每 1ms 错开 1us (cycleCount 低 10 位 = 节点号)
            for (Integer n = 1; n < valueOf(TEST_NODE_NUM); n = n + 1) begin
                if (fromInteger(n) <= activeSendersOf(stage)
                    && cycleCount % fromInteger(sendDeltaUs * valueOf(US_CYCLES)) == fromInteger(n)) begin
                    let txReq = getEmptyMacEvent;
                    txReq.srcMacId = fromInteger(n);
                    txReq.dstMacId = 0;
                    txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
                    txReq.mpduDigest.length = fromInteger(pktLen);
                    txReq.rfParam.power = txPower;
                    txReq.rfParam.mcs = 7;                             // MCS7 = 54Mbps
                    txReq.mpduDigest.duration = truncate((stage >= 6) ? durRtsOn : durRtsOff);
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
                // 应用吞吐 = N*1500*8/T_us, T=100000us -> Mbps = N*12/100
                UInt#(64) thrX100 = zeroExtend(stageRecv) * 60; // Mbps*100 = N*1500*8/20000*100 (1500B 口径)
                $display("[BIANCHI] stage=%0d rts=%0d senders=%0d recv=%0d total=%0d thr=%0d.%02d Mbps",
                         stage, (stage >= 6) ? 1 : 0, activeSendersOf(stage),
                         stageRecv, recvTotal, thrX100 / 100, thrX100 % 100);
                if (logFile != InvalidFile)
                    $fwrite(logFile, "STAGE %0d %0d %0d %0d %0d\n",
                            stage, (stage >= 6) ? 1 : 0, activeSendersOf(stage),
                            stageRecv, recvTotal);
                stageRecv <= 0;
                if (stage + 1 == fromInteger(nStages)) begin
                    phase <= PH_DONE;
                end else begin
                    stage <= stage + 1;
                    stageEndCycle <= cycleCount + fromInteger(stageUs * valueOf(US_CYCLES));
                    if (stage == 5) begin
                        cfgIdx <= 0;
                        phase <= PH_RTS0;
                    end
                end
            end
        end

        PH_DONE: begin
            $display("[BIANCHI] all %0d stages done, total received %0d", nStages, recvTotal);
            $finish();
        end
        endcase
    endrule

endmodule
