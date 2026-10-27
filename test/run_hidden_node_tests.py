#!/usr/bin/env python3
"""隐藏节点最大干扰模型的定向回归；产物统一写入 --output。"""
import run_deadlock_tests as runner
import argparse
import sys

runner.CASES = {
    "peak-interference": ("TestPhyPeakInterference.bsv", "mkTestPhyPeakInterference", {}),
    "peak-interference-fast": ("TestPhyPeakInterference.bsv", "mkTestPhyPeakInterference", {"REALEMU_US_CYCLES": 50}),
    "rxstart-response": ("TestDeadlockP2P.bsv", "mkTestDeadlockP2P", {"P2P_RXSTART_TIMEOUT": None}),
    "backoff-streams": ("TestBackoffStreams.bsv", "mkTestBackoffStreams", {}),
    "mac-read-progress": ("TestMacReadProgress.bsv", "mkTestMacReadProgress", {}),
    "sifs-ack": ("TestSifsResponse.bsv", "mkTestSifsResponse", {}),
    "sifs-cts": ("TestSifsResponse.bsv", "mkTestSifsResponse", {"SIFS_CTS": None}),
    "rx-completion-retention": ("TestRxCompletionRetention.bsv", "mkTestRxCompletionRetention", {}),
    "phy-air-time": ("TestAirTimeline.bsv", "mkTestPhyAirTime", {}),
    "arbiter-air-order": ("TestAirTimeline.bsv", "mkTestArbiterAirOrder", {"AIR_ARBITER_TEST": None}),
    "arbiter-tail-interference": ("TestArbiterTailInterference.bsv", "mkTestArbiterTailInterference", {}),
    "arbiter-tail-interference-fast": ("TestArbiterTailInterference.bsv", "mkTestArbiterTailInterference", {"REALEMU_US_CYCLES": 50}),
    "cts-nav-reservation": ("TestCtsNavReservation.bsv", "mkTestCtsNavReservation", {}),
    "half-duplex-timeline": ("TestHalfDuplexTimeline.bsv", "mkTestHalfDuplexTimeline", {}),
    "backoff-full-slot": ("TestBackoffFullSlot.bsv", "mkTestBackoffFullSlot", {}),
    "packet-random-retention": ("TestPacketRandomRetention.bsv", "mkTestPacketRandomRetention", {}),
    "cw-failure-sequence": ("TestCwFailureSequence.bsv", "mkTestCwFailureSequence", {}),
    "hidden16": ("TestHidden16.bsv", "mkTestHidden16", {}),
    # 只加速统计实验的统一模型时基；默认硬件仍250。须与250的样本交叉验证。
    "hidden16-fast": ("TestHidden16.bsv", "mkTestHidden16", {"REALEMU_US_CYCLES": 50}),
    "hidden16-burst": ("TestHidden16.bsv", "mkTestHidden16", {"HIDDEN_FINITE_BURST": None}),
}

if __name__ == "__main__":
    # 仅改变编译期仿真种子；硬件默认种子和公共测试执行器参数保持原约定。
    seed_parser = argparse.ArgumentParser(add_help=False)
    seed_parser.add_argument("--backoff-seed", type=int)
    options, rest = seed_parser.parse_known_args()
    if options.backoff_seed is not None:
        if not 0 <= options.backoff_seed < 65535:
            seed_parser.error("--backoff-seed must be in [0,65534]")
        runner.CASES = {name: (file, top, dict(defines, REALEMU_BACKOFF_SEED=options.backoff_seed))
                        for name, (file, top, defines) in runner.CASES.items()}
    sys.argv = [sys.argv[0], *rest]
    runner.main()
