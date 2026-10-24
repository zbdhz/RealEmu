#!/usr/bin/env python3
"""Build and run the Bluespec regression with isolated logs and RAM images."""
import argparse
import os
import signal
import hashlib
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
TESTS = {
    "reception": ("TestReceptionModel.bsv", "mkTestReceptionModel", "PASS reception model:"),
    "integration": ("TestMacPhyIntegration.bsv", "mkTestMacPhyIntegration", "PASS MAC PHY integration:"),
    "response": ("TestResponseTimeout.bsv", "mkTestResponseTimeout", "PASS response timeout:"),
    "lifecycle": ("TestPhyLifecycle.bsv", "mkTestPhyLifecycle", "PASS PHY lifecycle:"),
    "timing": ("TestFrameTiming.bsv", "mkTestFrameTiming", "PASS frame timing:"),
    "backoff": ("TestBackoff.bsv", "mkTestBackoff", "PASS backoff:"),

    "config": ("TestMacConfigApply.bsv", "mkTestMacConfigApply", "PASS MAC config:"),
    "timebase": ("TestTimebase.bsv", "mkTestTimebase", "PASS timebase:"),
    "collision": ("TestBsvTop_collision_v2.bsv", "mkTestRawEmuCore_collision_v2", "ALL TESTS PASSED"),
    "p2p-smoke": ("TestP2P.bsv", "mkTestP2PSmoke", "All 2 cases (MCS7 x RTS on/off) completed."),
    "p2p": ("TestP2P.bsv", "mkTestP2P", "All 16 cases (MCS0-7 x RTS on/off) completed."),
    "hidden": ("TestBsvTop_hidden_v2.bsv", "mkTestRawEmuCore_hidden_v2", "[HT] all 8 stages done"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", nargs="+", choices=TESTS, default=["config", "timebase", "timing", "backoff", "collision", "lifecycle", "reception", "response", "integration", "p2p-smoke"])
    parser.add_argument("--output", type=Path, default=ROOT / "test/build" / datetime.now().strftime("regression-%Y%m%d-%H%M%S"))
    parser.add_argument("--timeout", type=int, default=3600, help="Wall-clock seconds per simulation")
    parser.add_argument("--jobs", type=int, default=2, help="Concurrent simulations; builds remain serial")
    parser.add_argument("--define", action="append", default=[], help="Additional BSC define")
    args = parser.parse_args()
    bsc = shutil.which("bsc")
    if not bsc:
        parser.error("bsc is not on PATH; add the Bluespec toolchain bin directory")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    build = output / "build"
    build.mkdir()
    flags = ["-p", f"+:{ROOT / 'src'}:{ROOT / 'lib/src'}",
             "-bdir", str(build), "-info-dir", str(build), "-simdir", str(build), "-vdir", str(build)]
    manifest = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for folder in ("src", "test", "mem") for p in (ROOT / folder).glob("*")
                if p.is_file() and p.suffix in (".bsv", ".mem")}
    (output / "sources-sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
    commands = []
    results = []

    def simulate(name, executable, marker):
        run = output / name
        run.mkdir()
        for mem in (ROOT / "mem").glob("*.mem"):
            shutil.copy2(mem, run)
        (run / "bram_one.txt").write_text("8\n" * 1024)
        started = time.monotonic()
        try:
            with (run / "simulation.log").open("w") as log:
                proc = subprocess.Popen([str(executable)], cwd=run, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    proc.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                    raise
            text = (run / "simulation.log").read_text()
            passed = proc.returncode == 0 and marker in text and not re.search(r"\b(?:FAIL|FAILED|WATCHDOG)\b", text)
            if name in ("p2p", "p2p-smoke"):
                rows = re.findall(r"RESULT, case=(\d+), mcs=\d+, rts=\d+, recv=(\d+)/(\d+)", text)
                count = 2 if name == "p2p-smoke" else 16
                passed &= len(rows) == count and {int(r[0]) for r in rows} == set(range(count)) and all(r[1] == r[2] for r in rows)
            if name == "hidden":
                rows = re.findall(r"\[HT\] stage=(\d+) rts=\d+ senders=\d+ recvUnique=(\d+)", text)
                passed &= len(rows) == 8 and {int(r[0]) for r in rows} == set(range(8)) and all(int(r[1]) > 0 for r in rows)
            result = {"test": name, "passed": bool(passed), "returncode": proc.returncode}
        except subprocess.TimeoutExpired:
            result = {"test": name, "passed": False, "error": "simulation timeout"}
        result["seconds"] = round(time.monotonic() - started, 2)
        print(json.dumps(result), flush=True)
        return result

    futures = []
    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        for name in args.tests:
            source, top, marker = TESTS[name]
            executable = build / top
            compile_cmd = [bsc, "+RTS", "-K256M", "-RTS", "-sim", "-u", "-check-assert", "-promote-warnings", "G0021",
                           "-aggressive-conditions", "-lift", "-steps", "6000000", *flags,
                           *[x for d in args.define for x in ("-D", d)], "-g", top, str(ROOT / "test" / source)]
            link_cmd = [bsc, "-sim", "-Xc++", "-O1", "-parallel-sim-link", "16", *flags, "-e", top, "-o", str(executable)]
            print(f"Building {name}: {source}", flush=True)
            built = True
            with (output / f"{name}-build.log").open("w") as log:
                for command in (compile_cmd, link_cmd):
                    commands.append(command)
                    if subprocess.run(command, cwd=ROOT / "test", stdout=log, stderr=subprocess.STDOUT).returncode:
                        built = False
                        break
            if built:
                futures.append(executor.submit(simulate, name, executable, marker))
            else:
                result = {"test": name, "passed": False, "error": "build failed"}
                results.append(result)
                print(json.dumps(result), flush=True)
        results.extend(f.result() for f in futures)
    (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"Results: {output / 'results.json'}", flush=True)
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
