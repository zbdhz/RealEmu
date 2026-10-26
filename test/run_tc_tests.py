#!/usr/bin/env python3
"""T01/T02/C01/C02 unit and integration regressions; all outputs stay in output/."""
import run_deadlock_tests as runner

runner.CASES = {
    "clock-250": ("TestClockConfig.bsv", "mkTestModelClock", {}),
    "clock-200": ("TestClockConfig.bsv", "mkTestModelClock", {"REALEMU_US_CYCLES": 200}),
    "mac-config": ("TestClockConfig.bsv", "mkTestMacConfigApplied", {}),
    "cw-config": ("TestClockConfig.bsv", "mkTestCwConfigSwitch", {}),
    "phy-timing": ("TestPhyTiming.bsv", "mkTestPhyTiming", {}),
    "mac-bridge": ("TestBridgeBackpressure.bsv", "mkTestMacBridgeBackpressure", {}),
    "arbiter": ("TestBridgeBackpressure.bsv", "mkTestArbiterBackpressure", {}),
    "cfg-bridge": ("TestBridgeBackpressure.bsv", "mkTestCfgBridgeCompletion", {}),
    "config-fence": ("TestConfigFence.bsv", "mkTestConfigFence", {}),
    "p2p": ("TestDeadlockP2P.bsv", "mkTestDeadlockP2P", {}),
}

if __name__ == "__main__":
    runner.main()
