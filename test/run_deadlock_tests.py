#!/usr/bin/env python3
"""Build isolated D01-D03 simulations; save all generated files under output/.

--baseline builds the tracked HEAD sources instead of the working tree, so the
same tests can prove that the original defects fail and the patch repairs them.
Every run needs a new output directory. No board access or sudo is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "mac-rts": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {}),
    "mac-data": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"NO_RTS": None}),
    "overlap-data": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"INJECT_CYCLE": 28803}),
    "overlap-before": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"INJECT_CYCLE": 28802}),
    "overlap-same": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"INJECT_CYCLE": 28804}),
    "overlap-after": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"INJECT_CYCLE": 28805}),
    "overlap-cts": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"INJECT_CYCLE": 28803, "INJECT_CTS": None}),
    "read-done-before": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"PROBE_CYCLE": 28802}),
    "read-done-at": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"PROBE_CYCLE": 28803}),
    "read-done-after": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"PROBE_CYCLE": 28804}),
    "read-txend-before": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"PROBE_CYCLE": 39220}),
    "read-txend-at": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"PROBE_CYCLE": 39221}),
    "read-txend-after": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"PROBE_CYCLE": 39222}),
    "read-burst": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"READ_BURST_START": 39000, "READ_BURST_END": 120000}),
    "write-done-at": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"PROBE_CYCLE": 28803, "PROBE_WRITE": None}),
    "write-txend-at": ("TestMacPhyDeadlock.bsv", "mkTestMacPhyDeadlock", {"PROBE_CYCLE": 39221, "PROBE_WRITE": None}),
    "mac-backpressure": ("TestDeadlockBackpressure.bsv", "mkTestMacBackpressure", {}),
    "csma-handshake": ("TestDeadlockBackpressure.bsv", "mkTestCsmaDoneHandshake", {}),
    "phy-backpressure": ("TestDeadlockBackpressure.bsv", "mkTestPhyTxBackpressure", {}),
    "phy-weak-rx": ("TestDeadlockBackpressure.bsv", "mkTestPhyTxBackpressure", {"WEAK_RX_BURST": None}),
    "mac-phy-tx-order": ("TestDeadlockBackpressure.bsv", "mkTestMacPhyTxOrder", {}),
    "mac-phy-data-order": ("TestDeadlockBackpressure.bsv", "mkTestMacPhyTxOrder", {"ORDER_DATA": None}),
    "p2p": ("TestDeadlockP2P.bsv", "mkTestDeadlockP2P", {}),
    "collision": ("TestBsvTop_collision_v2.bsv", "mkTestRawEmuCore_collision_v2", {}),
}


def verify_config_fence(directory, log, record, env, cycles_per_us):
    """Check actual consumers and replay a read-only internal fence probe."""
    nodes = [int(x) for x in re.findall(r"CONFIG_NODE_PASS node=(\d+)", log)]
    if nodes != [0, 3, 4, 15]:
        raise RuntimeError("configuration did not reach all group boundary nodes")
    gaps = {}
    for node in nodes:
        received = re.search(rf"\[\s*(\d+) ns\] recv data pkt in mac layer, my mac id is\s+{node},", log)
        ack = re.search(rf"\[\s*(\d+) ns\] send ACK pkt in mac layer, my mac id is\s+{node},", log)
        if not received or not ack:
            raise RuntimeError(f"missing DATA/ACK timing for node {node}")
        # Bluesim's default clock is 10 time units/cycle; the model's microsecond
        # is US_CYCLES cycles. The usGen phase allows less than one us of error.
        gap = (int(ack[1]) - int(received[1])) // 10
        expected = (node + 4) * cycles_per_us
        if not expected - cycles_per_us < gap <= expected + 20:
            raise RuntimeError(f"node {node} SIFS not applied: {gap} cycles")
        gaps[str(node)] = {"cycles": gap, "model_us": gap / cycles_per_us}
    submitted = re.search(r"TRACE DATA_SUBMITTED cycle=(\d+) dst=0", log)
    first_send = re.search(r"\[\s*(\d+) ns\] send data pkt in mac layer", log)
    if not submitted or not first_send:
        raise RuntimeError("missing configuration fence trace")
    sample = int(submitted[1]) + 16
    released = int(first_send[1]) // 10 + 1
    if released <= sample:
        raise RuntimeError("no configuration backlog at fence sample")
    probe = directory / "inspect-config.tcl"
    probe.write_text(f"sim step {sample}\n"
                     'puts "FENCE_PENDING [sim get [sim lookup core.cfgPending]]"\n'
                     'puts "FENCE_MAC_INPUT [sim get [sim lookup core.macNodes_1_mac_fifoin_count]]"\n'
                     f"sim step {released - sample}\n"
                     'puts "FENCE_RELEASED [sim get [sim lookup core.cfgPending]]"\n')
    command = [str(directory / "simulate"), "-f", str(probe)]
    with (directory / "inspect-config.log").open("w") as probe_log:
        result = subprocess.run(command, cwd=directory, env=env,
                                stdout=probe_log, stderr=subprocess.STDOUT, timeout=60)
    text = (directory / "inspect-config.log").read_text()
    values = {key: int(value, 16) for key, value in
              re.findall(r"FENCE_(PENDING|MAC_INPUT|RELEASED)\s+\d+'h([0-9a-fA-F]+)", text)}
    if result.returncode or set(values) != {"PENDING", "MAC_INPUT", "RELEASED"}:
        raise RuntimeError("configuration fence probe failed")
    if values["PENDING"] == 0 or values["MAC_INPUT"] != 0 or values["RELEASED"] != 0:
        raise RuntimeError(f"DATA crossed an incomplete configuration fence: {values}")
    record.update(configured_nodes=nodes, sifs=gaps, fence_probe=values,
                  probe_command=command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--build-only", action="store_true",
                        help="freeze/compile/link only; report BUILT, without a simulation PASS")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--bsc", default=shutil.which("bsc") or
                        "/home/gtx/env/bsc-2025.01.1-ubuntu-22.04/bin/bsc")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = output / "source"
    source.mkdir()
    # Freeze sources before building; never reuse a build from a different case.
    paths = [*sorted((ROOT / "src").glob("*.bsv")),
             *sorted((ROOT / "lib/src").glob("*.bsv")),
             *sorted((ROOT / "mem").glob("*.mem"))]
    paths.append(ROOT / "scripts/genRam.py")
    manifest = {}
    for path in paths:
        relative = path.relative_to(ROOT)
        data = (subprocess.check_output(["git", "show", "HEAD:" + str(relative)], cwd=ROOT)
                if args.baseline and relative.parts[0] != "lib" else path.read_bytes())
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        manifest[str(relative)] = hashlib.sha256(data).hexdigest()
    env = dict(os.environ)
    env["PATH"] = str(Path(args.bsc).resolve().parent) + os.pathsep + env.get("PATH", "")
    version = subprocess.run([args.bsc, "-v"], env=env, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True).stdout
    types_text = (source / "src/Types.bsv").read_text()
    frequency = re.search(r"`define REALEMU_US_CYCLES (\d+)", types_text)
    if not frequency:
        frequency = re.search(r"typedef (\d+) US_CYCLES", types_text)
    cycles_per_us = int(frequency[1])
    context = {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               "baseline": args.baseline, "cycles_per_us": cycles_per_us,
               "bsc": version, "sha256": manifest}
    (output / "manifest.json").write_text(json.dumps(context, indent=2) + "\n")
    summaries = []
    selected = list(args.case or CASES)
    boundary_cases = {name for name in selected if name.startswith(("read-", "write-", "overlap-"))}
    if boundary_cases:
        selected = ["mac-rts"] + [name for name in selected if name != "mac-rts"]
    reference_send = reference_end = None
    for name in selected:
        filename, top, defines = CASES[name]
        defines = dict(defines)
        # Locate boundaries in a fresh reference run; clock/config propagation
        # changes must not silently move register probes away from the event.
        if name in boundary_cases and reference_send is not None:
            if "INJECT_CYCLE" in defines:
                offset = {"overlap-before": -3, "overlap-same": -1, "overlap-after": 0}.get(name, -2)
                defines["INJECT_CYCLE"] = reference_send + offset
            if "PROBE_CYCLE" in defines:
                at = reference_end - 1 if "txend" in name else reference_send - 2
                offset = -1 if name.endswith("before") else (1 if name.endswith("after") else 0)
                defines["PROBE_CYCLE"] = at + offset
            if name == "read-burst":
                defines["READ_BURST_START"] = reference_end - 2 * cycles_per_us
                defines["READ_BURST_END"] = reference_end + 400 * cycles_per_us
        directory = output / name
        directory.mkdir()
        test_data = (ROOT / "test" / filename).read_bytes()
        (directory / filename).write_bytes(test_data)
        for memory in (source / "mem").glob("*.mem"):
            shutil.copy2(memory, directory / memory.name)
        # The full core loads its channel BRAM from this generated file too.
        with (directory / "memory-init.log").open("w") as memory_log:
            subprocess.run([sys.executable, str(source / "scripts/genRam.py")], cwd=directory,
                           stdout=memory_log, stderr=subprocess.STDOUT, check=True, timeout=30)
        flags = ["-p", f"+:{source / 'src'}:{source / 'lib/src'}",
                 "-bdir", str(directory), "-simdir", str(directory), "-info-dir", str(directory),
                 "-aggressive-conditions", "-lift", "-show-schedule", "-check-assert"]
        macros = [item for key, value in defines.items()
                  for item in ("-D", key if value is None else f"{key}={value}")]
        # Full-core debug symbol registration makes GCC -O3 model compilation
        # disproportionately expensive; -O0 preserves cycle accuracy for this integration test.
        link_opt = (["-Xc++", "-O0"] if name == "config-fence" else
                    ["-Xc++", "-O2"] if name.startswith("hidden16") else [])
        commands = [
            ("compile", [args.bsc, "+RTS", "-K512M", "-RTS", "-sim", "-u", *flags, *macros, "-g", top, str(directory / filename)]),
            ("link", [args.bsc, "-sim", "-parallel-sim-link", "4", *link_opt, *flags, "-e", top, "-o", str(directory / "simulate")]),
            ("simulate", [str(directory / "simulate")]),
        ]
        if args.build_only:
            commands = commands[:2]
        record = {"case": name, "defines": defines, "test_sha256": hashlib.sha256(test_data).hexdigest(),
                  "stages": [], "passed": False}
        try:
            for stage, command in commands:
                start = time.monotonic()
                with (directory / (stage + ".log")).open("w") as log:
                    result = subprocess.run(command, cwd=directory, env=env,
                                            stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
                record["stages"].append({"stage": stage, "command": command,
                                         "returncode": result.returncode, "seconds": time.monotonic() - start})
                if result.returncode:
                    raise RuntimeError(f"{stage} exited {result.returncode}")
                if stage == "compile":
                    compile_log = (directory / "compile.log").read_text()
                    # BSC may exit zero even when a rule can never execute.
                    if "G0021" in compile_log:
                        raise RuntimeError("BSC generated a rule that can never fire (G0021)")
            if args.build_only:
                record.update(built=True, passed=None)
                (directory / "commands.json").write_text(json.dumps(record, indent=2) + "\n")
                summaries.append(record)
                (output / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
                print(name, "BUILT (simulation not run)", flush=True)
                continue
            log = (directory / "simulate.log").read_text()
            record["results"] = re.findall(r"^(?:RESULT|CASE_PASS|TEST_PASS|TEST_FAIL|TXEND_HIGH_CYCLES).*", log, re.M)
            record["warnings"] = re.findall(r"\((G\d+)\)", (directory / "compile.log").read_text())
            passed_marker = ("[V2] pass=4 fail=0" in log and "ALL TESTS PASSED" in log
                             if name == "collision" else "TEST_PASS " in log)
            if not passed_marker or "TEST_FAIL " in log:
                raise RuntimeError("simulation did not explicitly pass")
            if name == "collision":
                record["results"].extend(line for line in log.splitlines() if line.startswith("[V2]"))
            if name == "p2p" and log.count("CASE_PASS ") != 16:
                raise RuntimeError("not all 16 P2P cases finished")
            if name == "config-fence":
                verify_config_fence(directory, log, record, env, cycles_per_us)
            if name == "mac-rts":
                sends = re.findall(r"\[\s*(\d+) ns\] send rts pkt", log)
                ends = re.findall(r"TRACE cycle=(\d+) PHY_END", log)
                if sends and ends:
                    reference_send, reference_end = int(sends[0]) // 10, int(ends[0])
            if name == "read-burst":
                starts = [int(x) for x in re.findall(r"TRACE cycle=(\d+) PHY_START", log)]
                # With an independent timer the first timeout has elapsed while
                # reads run. After reads stop, only DIFS + CW31 backoff remains.
                if len(starts) < 2 or starts[1] > defines["READ_BURST_END"] + (34 + 31 * 9) * cycles_per_us + 100:
                    raise RuntimeError("register reads paused the response timer")
            if name in ("mac-phy-tx-order", "mac-phy-data-order"):
                # Replay deterministically with a read-only Bluesim probe just
                # after the first RTS TX_END. A previous ACK must not have
                # started its timer: the correct value here is exactly one.
                subtype = 0 if name == "mac-phy-data-order" else 11
                starts = re.findall(rf"TRACE cycle=(\d+) CHANNEL_OUT subtype={subtype}$", log, re.M)
                endings = [x for x in re.findall(rf"TRACE cycle=(\d+) TX_END subtype={subtype}$", log, re.M)
                           if starts and int(x) > int(starts[0])]
                if not endings:
                    raise RuntimeError("no RTS TX_END observed")
                probe = directory / "inspect.tcl"
                probe.write_text(f"sim step {int(endings[0])}\n"
                                 'puts "TIMER_BEFORE_RTS_END [sim get [sim lookup mac_ackTimeoutCountReg]]"\n'
                                 'sim step 2\n'
                                 'puts "TIMER_AT_RTS_END [sim get [sim lookup mac_ackTimeoutCountReg]]"\n')
                command = [str(directory / "simulate"), "-f", str(probe)]
                with (directory / "inspect.log").open("w") as probe_log:
                    result = subprocess.run(command, cwd=directory, env=env,
                                            stdout=probe_log, stderr=subprocess.STDOUT, timeout=60)
                record["probe_command"] = command
                probe_text = (directory / "inspect.log").read_text()
                before = re.search(r"TIMER_BEFORE_RTS_END\s+16'h([0-9a-fA-F]+)", probe_text)
                after = re.search(r"TIMER_AT_RTS_END\s+16'h([0-9a-fA-F]+)", probe_text)
                if (result.returncode or not before or not after
                        or int(before[1], 16) != 0 or int(after[1], 16) != 1):
                    raise RuntimeError("a prior control TX_END started the RTS timer")
                record["timer_before_first_rts_end"] = 0
                record["timer_at_first_rts_end"] = 1
            record["passed"] = True
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            record["error"] = str(error)
        (directory / "commands.json").write_text(json.dumps(record, indent=2) + "\n")
        summaries.append(record)
        (output / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
        print(name, "PASS" if record["passed"] else "FAIL " + record.get("error", ""), flush=True)
    success = all(item.get("built", False) if args.build_only else item["passed"] for item in summaries)
    raise SystemExit(0 if success else 1)


if __name__ == "__main__":
    main()
