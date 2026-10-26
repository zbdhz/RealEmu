// ============================================================================
// TestP2P.bsv - 点到点吞吐与延时测试
//
// 测试内容:
//   node1 -> node0 单跳链路, 扫描 MCS 0-7 x RTS on/off 共 16 个 case
//   每个 case 分两段:
//     段A(吞吐): 背靠背灌 burstN 个 DATA 帧, MAC FIFO(深10)自然反压,
//                吞吐 = 总bit / (末包接收时刻 - 首包入队时刻)
//     段B(延时): 单发 rttN 个 DATA 帧(收到一个再发下一个),
//                用 MpduDigest.cacheAddr 携带发送周期号, 测单包延时
//
// 配置(全部通过 AXI-Lite 驱动配置接口, 不改 src 主程序):
//   - PER 表通过 bridgeTag{control=1,notUsed=1} 灌 0xFFFF(理想信道, 必 CRC OK)
//     (注意: perWire >= random 才判 CRC OK, 灌 0 会导致全丢包)
//   - node1/node0 MAC 寄存器对齐 ns-3 802.11a: timeout=70, cwMax=10,
//     retryLimit=7; rtsThreshold 按 case 切换(off=65535, on=100)
//
// 时标: Types.US_CYCLES（默认250）；模型µs=cycle/C，不能直接把$time当模型时间。
//
// 结构说明: 严格单写者 —— controller 是 phase/AXI-Lite 握手/发包的
// 唯一规则; recvPacket 只写收包统计寄存器且不读 controller 的任何
// 寄存器, 避免 G0010 调度环(-promote-warnings ALL 下为错误).
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
import SemiFifo::*;
import DReg::*;

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

`define BSIM;

// ---- 测试参数 ----
Integer burstN        = 10;        // 段A 吞吐测试包数
Integer rttN          = 5;         // 段B 延时测试包数
Integer pktLen        = 1500;      // DATA 帧长 (byte)
Int#(12)  txPower     = fromInteger(1920); // 60dBm (Q6.5), 与现有测试一致
UInt#(32) caseWd      = 20000000;  // 单 case 看门狗 (cycles), 最长 case ~7M
Bit#(32)  rtsThOff    = 65535;     // 恒不触发 RTS
Bit#(32)  rtsThOn     = 100;       // length=1500 > 100 触发 RTS
Bit#(32)  toOff       = 70;        // RTS off: ns-3 对齐 ACK timeout (us)
Bit#(32)  toOn        = 70;         // RTS on: BUG-A/B 已修复, 恢复 ns-3 对齐值

// AXI-Lite 节点地址 helper
function Bit#(32) nodeAddr(Integer node, Bit#(32) off);
    return node_base_addr + node_per_node * fromInteger(node) + off;
endfunction

// 初始配置表 (对齐 ns-3): timeout=70, cwMax=10, retryLimit=7
function Tuple2#(Bit#(32), Bit#(32)) initCfgEntry(UInt#(4) i);
    case (i)
        0:  return tuple2(nodeAddr(1, mac_timeout_off),     70);
        1:  return tuple2(nodeAddr(1, mac_cw_max_off),      10);
        2:  return tuple2(nodeAddr(1, mac_retry_limit_off), 7);
        3:  return tuple2(nodeAddr(0, mac_timeout_off),     70);
        4:  return tuple2(nodeAddr(0, mac_cw_max_off),      10);
        5:  return tuple2(nodeAddr(0, mac_retry_limit_off), 7);
        6:  return tuple2(nodeAddr(1, mac_rts_thresh_off),  rtsThOff);
        7:  return tuple2(nodeAddr(0, mac_rts_thresh_off),  rtsThOff);
    endcase
endfunction

typedef enum {
    PH_PER,         // PER 表初始化
    PH_CFG0,        // 初始配置: 发起写
    PH_CFG1,        // 初始配置: 等 awReady/wReady
    PH_CFG2,        // 初始配置: 等 bValid
    PH_CASE0,       // 每 case 写 rtsThreshold: 发起
    PH_CASE1,       // 等 ready
    PH_CASE2,       // 等 bValid
    PH_THR,         // 段A: 背靠背发包
    PH_RTT,         // 段B: 单发测 RTT
    PH_REPORT,      // 打印结果
    PH_DONE         // 结束
} TestPhase deriving (Eq, Bits);

typedef enum {
    RCV_BURST,      // 正在收 burst 段
    RCV_RTT,        // 正在收 RTT 段
    RCV_DONE        // 本 case 收完, 等下一 case 首包
} RecvSeg deriving (Eq, Bits);

module mkTestP2P(Empty);
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
    Reg#(UInt#(32)) cycleCount <- mkReg(0);
    Reg#(UInt#(32)) initIdx <- mkReg(0);

    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    // case 参数派生: 0-7 = RTS off mcs0-7, 8-15 = RTS on mcs0-7
    function Bool caseRtsOn(UInt#(6) c); return c >= 8; endfunction
    function Bit#(4) caseMcs(UInt#(6) c);
        UInt#(6) m = caseRtsOn(c) ? (c - 8) : c;
        return truncate(pack(m));
    endfunction

    // ---- 发送公共函数: 构造 DATA 帧并注入 core.tx ----
    function Action sendOnePacket(Bit#(4) mcs, UInt#(32) timestamp);
    action
        MacEvent txReq = getEmptyMacEvent;
        txReq.srcMacId = 1;
        txReq.dstMacId = 0;
        txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        txReq.mpduDigest.length = fromInteger(pktLen);
        txReq.mpduDigest.cacheAddr = zeroExtend(pack(timestamp));
        txReq.rfParam.power = txPower;
        txReq.rfParam.mcs = mcs;
        txReq.mpduDigest.duration = 2164;
        let bridgeTag = getEmptyBridgeTag();
        AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
            tData: zeroExtend(pack(tuple2(txReq, bridgeTag))),
            tKeep: '1,
            tLast: True,
            tUser: 0
        };
        core.tx.put(axiPkt);
    endaction
    endfunction

    // =====================================================================
    // recvPacket: 唯一收包规则, 只写下列统计寄存器, 不读 controller 寄存器
    // =====================================================================
    Reg#(RecvSeg)     recvSeg    <- mkReg(RCV_DONE);
    Reg#(UInt#(32))   burstRcvCnt <- mkReg(0);   // 本 case 已收 burst 包数
    Reg#(UInt#(32))   rttRcvCnt  <- mkReg(0);    // 本 case 已收 RTT 包数
    Reg#(Bool)        burstDone  <- mkReg(False); // burst 段收满 (电平)
    Reg#(Bool)        rttDone    <- mkReg(False); // RTT 段收满 (电平)
    Reg#(UInt#(32))   thrT1      <- mkReg(0);    // 末包接收时刻
    Reg#(UInt#(32))   rttMin     <- mkReg(maxBound);
    Reg#(UInt#(32))   rttMax     <- mkReg(0);
    Reg#(UInt#(64))   rttSum     <- mkReg(0);

    rule recvPacket;
        let rxpkt <- core.rx.get;
        MacEvent rxReq = unpack(truncate(rxpkt.tData));
        UInt#(32) ts = unpack(truncate(rxReq.mpduDigest.cacheAddr));
        UInt#(32) lat = cycleCount - ts;

        case (recvSeg)
        RCV_DONE: begin
            // 下一 case 的首个 burst 包, 全量自复位
            recvSeg <= RCV_BURST;
            burstRcvCnt <= 1;
            rttRcvCnt <= 0;
            burstDone <= False;
            rttDone <= False;
            thrT1 <= cycleCount;
        end
        RCV_BURST: begin
            burstRcvCnt <= burstRcvCnt + 1;
            thrT1 <= cycleCount;
            if (burstRcvCnt + 1 == fromInteger(burstN)) begin
                recvSeg <= RCV_RTT;
                burstDone <= True;
            end
        end
        RCV_RTT: begin
            rttRcvCnt <= rttRcvCnt + 1;
            // 每 case 第一个 RTT 包自复位 min/max/sum
            if (rttRcvCnt == 0) begin
                rttMin <= lat; rttMax <= lat; rttSum <= zeroExtend(lat);
            end else begin
                rttSum <= rttSum + zeroExtend(lat);
                if (lat < rttMin) rttMin <= lat;
                if (lat > rttMax) rttMax <= lat;
            end
            $display("[P2P] rtt #%0d lat=%0d cycles (%0d us)",
                     rttRcvCnt, lat, lat / fromInteger(valueOf(US_CYCLES)));
            if (rttRcvCnt + 1 == fromInteger(rttN)) begin
                recvSeg <= RCV_DONE;
                rttDone <= True;
            end
        end
        endcase
    endrule

    // =====================================================================
    // controller: 唯一写 phase 的规则, 完成 PER 初始化/AXI-Lite 配置/发包
    // =====================================================================
    Reg#(TestPhase) phase <- mkReg(PH_PER);
    Reg#(UInt#(6)) caseIdx <- mkReg(0);
    Reg#(UInt#(4)) cfgCount <- mkReg(0);
    Reg#(UInt#(32)) burstSent <- mkReg(0);
    Reg#(UInt#(32)) rttSent <- mkReg(0);
    Reg#(UInt#(32)) thrT0 <- mkReg(0);
    Reg#(UInt#(32)) caseStartCycle <- mkReg(0);

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
                    $display("[P2P] PER table initialized: 16383 entries all-pass (0xFFFF)");
                    phase <= PH_CFG0;
                end
            end
        end

        // ---------- 初始配置 (8 笔, 对齐 ns-3) ----------
        PH_CFG0: begin
            match {.a, .d} = initCfgEntry(cfgCount);
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
                if (cfgCount + 1 == 8) begin
                    cfgCount <= 0;
                    $display("[P2P] ns-3 aligned cfg done: timeout=70 cwMax=10 retryLimit=7");
                    phase <= PH_CASE0;
                end else begin
                    cfgCount <= cfgCount + 1;
                    phase <= PH_CFG0;
                end
            end
        end

        // ---------- 每 case 写 rtsThreshold + timeout (4 笔) ----------
        PH_CASE0: begin
            Bit#(32) rtsVal = caseRtsOn(caseIdx) ? rtsThOn : rtsThOff;
            Bit#(32) toVal  = caseRtsOn(caseIdx) ? toOn : toOff;
            Bit#(32) off    = (cfgCount == 0 || cfgCount == 2) ? mac_rts_thresh_off
                              : mac_timeout_off;
            Bit#(32) val    = (cfgCount == 0 || cfgCount == 2) ? rtsVal : toVal;
            Integer node    = (cfgCount < 2) ? 1 : 0;
            awAddr <= nodeAddr(node, off);
            wData <= val; wStrb <= '1;
            awValid <= True; wValid <= True;
            phase <= PH_CASE1;
        end
        PH_CASE1: begin
            if (core.dmaAxiLiteSlave.wrSlave.awReady &&
                core.dmaAxiLiteSlave.wrSlave.wReady) begin
                awValid <= False; wValid <= False; bReady <= True;
                phase <= PH_CASE2;
            end
        end
        PH_CASE2: begin
            if (core.dmaAxiLiteSlave.wrSlave.bValid) begin
                bReady <= False;
                if (cfgCount + 1 == 4) begin
                    cfgCount <= 0;
                    $display("[P2P] ===== case %0d: MCS %0d RTS %0d (rtsThreshold=%0d) =====",
                             caseIdx, caseMcs(caseIdx),
                             caseRtsOn(caseIdx) ? 1 : 0,
                             caseRtsOn(caseIdx) ? rtsThOn : rtsThOff);
                    caseStartCycle <= cycleCount;
                    burstSent <= 0;
                    rttSent <= 0;
                    phase <= PH_THR;
                end else begin
                    cfgCount <= cfgCount + 1;
                    phase <= PH_CASE0;
                end
            end
        end

        // ---------- 段A: 背靠背灌包, burstDone 且全部发出即切段 ----------
        PH_THR: begin
            if (burstSent < fromInteger(burstN) && cycleCount % 50 == 0) begin
                sendOnePacket(caseMcs(caseIdx), cycleCount);
                if (burstSent == 0) thrT0 <= cycleCount;
                burstSent <= burstSent + 1;
            end
            // burstDone 是电平信号, 上一 case 残留 True 直到本 case 首包接收
            // 才被清除; 而 burstSent==N 在进入 PH_THR 后 ~500 cycles 即达成,
            // 远早于首个 RTS/CTS/DATA 往返(~ms), 会误切. 加 thrT1 > caseStartCycle
            // 保证本 case 内真实收到过包(thrT1 每次接收都刷新)才允许切段
            if (burstDone && burstSent == fromInteger(burstN)
                && thrT1 > caseStartCycle) begin
                $display("[P2P] burst done: %0d pkt received @cycle %0d",
                         burstN, cycleCount);
                phase <= PH_RTT;
            end
        end

        // ---------- 段B: 单发测 RTT (收到上一个才发下一个) ----------
        PH_RTT: begin
            if (rttSent < fromInteger(rttN)
                && rttRcvCnt == rttSent
                && cycleCount % 100 == 0) begin
                sendOnePacket(caseMcs(caseIdx), cycleCount);
                rttSent <= rttSent + 1;
            end
            if (rttDone && rttSent == fromInteger(rttN)) begin
                phase <= PH_REPORT;
            end
        end

        // ---------- 打印结果, 进入下一 case ----------
        PH_REPORT: begin
            UInt#(64) bitsTotal = fromInteger(burstN * pktLen * 8);
            UInt#(64) dur = zeroExtend(thrT1 - thrT0);
            UInt#(64) thrMbps = (dur == 0) ? 0 : (bitsTotal * fromInteger(valueOf(US_CYCLES)) / dur);
            UInt#(64) rttAvg = rttSum / fromInteger(rttN);

            $display("[P2P] RESULT, case=%0d, mcs=%0d, rts=%0d, recv=%0d/%0d, thr=%0d Mbps, rtt_min=%0d us, rtt_avg=%0d us, rtt_max=%0d us",
                     caseIdx, caseMcs(caseIdx), caseRtsOn(caseIdx) ? 1 : 0,
                     burstRcvCnt, burstN, thrMbps,
                     rttMin / fromInteger(valueOf(US_CYCLES)), rttAvg / fromInteger(valueOf(US_CYCLES)), rttMax / fromInteger(valueOf(US_CYCLES)));
            $display("[P2P]        detail: t0=%0d t1=%0d dur_cycles=%0d, rtt_cycles min=%0d avg=%0d max=%0d",
                     thrT0, thrT1, dur, rttMin, rttAvg, rttMax);

            caseIdx <= caseIdx + 1;
            if (caseIdx + 1 == 16)
                phase <= PH_DONE;
            else
                phase <= PH_CASE0;
        end

        PH_DONE: begin
            $display("[P2P] All 16 cases (MCS0-7 x RTS on/off) completed.");
            $finish();
        end
        endcase
    endrule

    // ==================== 看门狗 (只读 controller 寄存器) ====================
    rule caseWatchdog (phase != PH_PER && phase != PH_DONE);
        if (cycleCount - caseStartCycle > caseWd) begin
            $display("[P2P] WATCHDOG timeout at case %0d phase %0d cycle %0d, burstRcv=%0d rttRcv=%0d",
                     caseIdx, pack(phase), cycleCount, burstRcvCnt, rttRcvCnt);
            $finish();
        end
    endrule

endmodule
