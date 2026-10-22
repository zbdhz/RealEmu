// ============================================================================
// TestBsvTop_collision_v2.bsv - PHY 级碰撞模型验证 (双败 + CS 门限)
//
// 验证目标 (对齐 doc/collision-model-alignment-proposal.md):
//   T1 错开成功 : 强帧(d8, rx=1422) 单发 -> dut0 CRC OK 收到
//   T2 重叠双败 : 两条强帧相隔 ~30us 到达 dut0 -> markCollision 置位,
//                 先到帧 CRC ERROR, 后到帧不接收 => dut0 一帧都收不到
//   T3 弱帧隐藏 : 弱帧(d1023, rx=74 < csThreash128) 不进 SYNC, dut0 无感
//                 (且不武装 CCA)
//   T4 弱帧不构成干扰: 强帧接收中叠弱帧(74<128) -> 不判废, 强帧 CRC OK
//
// 注入方式: PHY 级直注 phyRxSrv (绕过 MAC/arbiter, 时序确定).
// 信道: 20lgd.mem loss = 32*20lg(d) (1/32dB); power=2000(62.5dBm):
//   d=8    -> loss 578  -> rx 1422 (44.4dBm)  强帧
//   d=1023 -> loss 1926 -> rx 74   (2.3dBm)   弱帧(隐藏)
// PER: mem/Per.mem 默认表, 强帧 SYNC(idx1119)/RX(highSNR) 均 FFFF 必过,
//      弱帧 SINR<lowSNR -> idx0 = 0 必败. 无需灌表.
// 时标: 200 cycles/us (clkFreq=200MHz, 1cycle=5ns? Bluesim $time=ns).
// ============================================================================

import GetPut::*;
import Connectable::*;
import ClientServer::*;

import Types::*;
import PhyCore::*;

typedef 8 TEST_NODE_NUM;

Integer  pktLen  = 1038;
Integer  dNear   = 8;      // -> rx 1422
Integer  dFar    = 1023;   // -> rx 74
Int#(12) txPower = fromInteger(2000);
// 32*20lg(d) 预计算 (与 mem/20lgd.mem 一致, 由 python 生成校验值)
Int#(12) lossNear = fromInteger(578);   // 32*20lg(8)  = 578
Int#(12) lossFar  = fromInteger(1926);  // 32*20lg(1023)= 1926

module mkTestRawEmuCore_collision_v2(Empty);

    PhyCore dut0 <- mkPhyYansWifi(0);   // 收端

    Reg#(UInt#(64)) cycleCount <- mkReg(0);
    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    // ---- RX 应答握手 (phyRxSrv response) ----
    rule handshakeRx;
        let resp <- dut0.phyRxSrv.response.get;
    endrule

    // ---- 收包统计 (lowMacRxClt, DATA 帧) ----
    Reg#(UInt#(32)) recvOk <- mkReg(0);
    Reg#(UInt#(32)) recvErr <- mkReg(0);
    rule receive;
        let rxReq <- dut0.lowMacRxClt.request.get;
        let respD = dut0.lowMacRxClt;
        recvOk <= recvOk + 1;
        $display("[%0d] RX OK src=%0d power=%0d",
                 cycleCount, rxReq.srcMacId, rxReq.rfParam.power);
    endrule

    // ---- 注入辅助: 直接向 dut0.phyRxSrv 放 PhyEvent ----
    function Action inject(Bit#(DEV_ID_WIDTH) src, Int#(12) rxP);
        return action
            let ev = getEmptyPhyEvent;
            ev.srcPhyId  = src;
            ev.dstPhyId  = 0;
            ev.rfParam.power = rxP;
            ev.rfParam.mcs   = 7;
            ev.ppduLen       = fromInteger(pktLen);
            ev.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
            ev.mpduDigest.length    = fromInteger(pktLen);
            dut0.phyRxSrv.request.put(ev);
            $display("[%0d] INJECT src=%0d rxPower=%0d", cycleCount, src, rxP);
        endaction;
    endfunction

    Int#(12) pNear = txPower - lossNear;   // 1422
    Int#(12) pFar  = txPower - lossFar;    // 74

    // ---- 测试调度 (cycle 精确) ----
    // 帧 SYNC 20us + DATA MCS7 1038B ~154us -> 全帧 ~174us = 34800 cycles
    // T2 重叠: 帧 B 在帧 A SYNC 后 30us (6000c) 注入 -> A 处于 SYNC 尾部/RX 头部
    Reg#(UInt#(32)) t1done <- mkReg(0);
    Reg#(UInt#(32)) t2done <- mkReg(0);
    Reg#(UInt#(32)) t3done <- mkReg(0);
    Reg#(UInt#(32)) t4done <- mkReg(0);
    Reg#(UInt#(32)) t1cnt  <- mkReg(0);
    Reg#(UInt#(32)) t2cnt  <- mkReg(0);
    Reg#(UInt#(32)) t3cnt  <- mkReg(0);
    Reg#(UInt#(32)) t4cnt  <- mkReg(0);
    Reg#(UInt#(32)) passCnt <- mkReg(0);
    Reg#(UInt#(32)) failCnt <- mkReg(0);

    // T1 @ 1000: 单发强帧; @ 1000+45000 判定
    rule t1_fire (cycleCount == 1000);
        inject(1, pNear);
    endrule
    rule t1_check (cycleCount == 1000 + 45000 && t1done == 0);
        t1done <= 1;
        if (recvOk == 1) begin passCnt <= passCnt + 1;
            $display("[V2] T1 staggered-ok PASS (recvOk=%0d)", recvOk);
        end else begin failCnt <= failCnt + 1;
            $display("[V2] T1 staggered-ok FAIL (recvOk=%0d, expect 1)", recvOk);
        end
        t1cnt <= recvOk;
    endrule

    // T2 @ 100000: 强帧A; @ +6000 强帧B (SYNC 20us 中段重叠); @ +45000 判定
    rule t2_fireA (cycleCount == 100000);
        inject(1, pNear);
    endrule
    rule t2_fireB (cycleCount == 106000);
        inject(2, pNear);
    endrule
    rule t2_check (cycleCount == 100000 + 45000 && t2done == 0);
        t2done <= 1;
        let got = recvOk - t1cnt;
        if (got == 0) begin passCnt <= passCnt + 1;
            $display("[V2] T2 overlap-both-lose PASS (recv delta=%0d)", got);
        end else begin failCnt <= failCnt + 1;
            $display("[V2] T2 overlap-both-lose FAIL (recv delta=%0d, expect 0)", got);
        end
        t2cnt <= recvOk;
    endrule

    // T3 @ 200000: 单发弱帧; @ +45000 判定 (无 SYNC, 无 CCA, 无接收)
    rule t3_fire (cycleCount == 200000);
        inject(2, pFar);
    endrule
    rule t3_check (cycleCount == 200000 + 45000 && t3done == 0);
        t3done <= 1;
        let got = recvOk - t2cnt;
        if (got == 0) begin passCnt <= passCnt + 1;
            $display("[V2] T3 weak-hidden PASS (recv delta=%0d)", got);
        end else begin failCnt <= failCnt + 1;
            $display("[V2] T3 weak-hidden FAIL (recv delta=%0d, expect 0)", got);
        end
        t3cnt <= recvOk;
    endrule

    // T4 @ 300000: 强帧; +6000 弱帧; @ +45000 判定 -> 强帧应 CRC OK
    rule t4_fireA (cycleCount == 300000);
        inject(1, pNear);
    endrule
    rule t4_fireB (cycleCount == 306000);
        inject(2, pFar);
    endrule
    rule t4_check (cycleCount == 300000 + 45000 && t4done == 0);
        t4done <= 1;
        let got = recvOk - t3cnt;
        if (got == 1) begin passCnt <= passCnt + 1;
            $display("[V2] T4 weak-not-jamming PASS (recv delta=%0d)", got);
        end else begin failCnt <= failCnt + 1;
            $display("[V2] T4 weak-not-jamming FAIL (recv delta=%0d, expect 1)", got);
        end
        t4cnt <= recvOk;
    endrule

    rule simEnd (cycleCount == 350000);
        $display("[V2] ================= SUMMARY =================");
        $display("[V2] pass=%0d fail=%0d", passCnt, failCnt);
        $display("[V2] %s",
                 (failCnt == 0) ? "ALL TESTS PASSED" : "SOME TESTS FAILED");
        $finish();
    endrule

endmodule
