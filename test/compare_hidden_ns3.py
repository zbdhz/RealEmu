#!/usr/bin/env python3
"""Compare identical 16-node MAC/PHY scenarios; keep every raw run in --output.

Build Bluesim with run_hidden_node_tests.py --case hidden16 first. Pass its
simulate path as --bsv. --long selects 20ms warmup + 100ms receive measurement.
ns-3 is linked from the supplied local build; its sources are never changed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def run(command, directory, log, timeout, env=None):
    start = time.monotonic()
    with log.open("w") as out:
        p = subprocess.run(command, cwd=directory, stdout=out, stderr=subprocess.STDOUT,
                           timeout=timeout, env=env)
    text = log.read_text()
    if p.returncode or "TEST_FAIL " in text:
        raise RuntimeError(f"failed: {log}")
    return text, time.monotonic() - start


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def scenario_body(path):
    # Reuse older points only when the test differs solely in CLI argument parsing.
    # The production sources, ROMs, compiler defines and measurement windows are
    # checked independently below; changed traffic/statistics must force a rerun.
    text = path.read_text()
    text, count = re.subn(r"(?ms)^    rule arguments\(cycle == 1\);.*?^    endrule\n",
                          "    // argument parsing\n", text)
    if count != 1:
        raise RuntimeError(f"cannot identify argument parser: {path}")
    return hashlib.sha256(text.encode()).hexdigest()


def write_runs(out, records):
    records = sorted(records, key=lambda r: (r["platform"], r["senders"], r["rts"], r["seed"]))
    write_json(out / "runs.json", records)
    columns = ["platform", "senders", "rts", "seed", "backoff_seed", "warm_us", "measure_us",
               "unique", "duplicates", "mbps", "submitted_packets", "acked_packets_at_stop",
               "cycles_per_us", "drained", "seconds", "reused_from", "log"]
    for name, rows in [("runs.csv", records),
                       ("realemu-runs.csv", [r for r in records if r["platform"] == "RealEmu"])]:
        with (out / name).open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=columns, extrasaction="ignore")
            writer.writeheader(); writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bsv", type=Path, action="append", required=True,
                        help="repeat for independently compiled backoff seeds")
    parser.add_argument("--ns3-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--long", action="store_true")
    parser.add_argument("--ns3-runs", type=int, default=10)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--senders", type=int, nargs="+", default=list(range(1, 16)),
                        choices=range(1, 16))
    parser.add_argument("--reuse-from", type=Path, action="append", default=[],
                        help="reuse verified points from a matching earlier comparison")
    parser.add_argument("--resume", action="store_true",
                        help="resume this output directory with identical experiment inputs")
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=args.resume)
    ns3 = args.ns3_root.resolve(); lib = ns3 / "build/lib"
    source = ROOT / "test/ns3-hidden-reference.cc"
    binary = out / "ns3-hidden-reference"
    modules = ["wifi", "spectrum", "propagation", "mobility", "network", "core"]
    paths = [p.resolve() for p in args.bsv]
    models = [{"path": str(p), "shared_library_sha256": digest(p.with_suffix(".so")),
               "source_manifest": json.loads((p.parent.parent / "manifest.json").read_text()),
               "build_cases": json.loads((p.parent.parent / "summary.json").read_text()),
               "test_sha256": digest(p.parent / "TestHidden16.bsv"),
               "scenario_body_sha256": scenario_body(p.parent / "TestHidden16.bsv")}
              for p in paths]
    library_hashes = {str(lib / f"libns3-dev-{name}-default.so"):
                      digest(lib / f"libns3-dev-{name}-default.so") for name in modules}
    ns3_head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ns3, text=True).strip()
    warm, measure = (20000, 100000) if args.long else (2000, 10000)
    context = {"warm_us": warm, "measure_us": measure, "senders": args.senders,
               "ns3_runs": args.ns3_runs, "models": models, "ns3_head": ns3_head,
               "ns3_source_sha256": digest(source), "ns3_libraries": library_hashes,
               "reuse_from": [str(p.resolve()) for p in args.reuse_from]}
    if args.resume:
        if json.loads((out / "experiment.json").read_text()) != context:
            raise RuntimeError("resume inputs differ from the frozen experiment")
    else:
        write_json(out / "experiment.json", context)
    shutil.copy2(source, out / source.name)
    shutil.copy2(Path(__file__), out / "compare_hidden_ns3.py")
    compile_cmd = ["g++", "-std=c++23", "-O2", "-I", str(ns3 / "build/include"), str(out / source.name),
                   "-L", str(lib), f"-Wl,-rpath,{lib}",
                   *[f"-lns3-dev-{name}-default" for name in modules], "-o", str(binary)]
    run(compile_cmd, ROOT, out / "compile-ns3.log", args.timeout)
    env = dict(os.environ)
    bsc_bin = "/home/gtx/env/bsc-2025.01.1-ubuntu-22.04/bin"
    env["PATH"] = bsc_bin + os.pathsep + env.get("PATH", "")
    jobs = [(n, rts) for n in args.senders for rts in (False, True)]

    def parse_real(text, n, rts, seed, seconds, log):
        m = re.search(r"HIDDEN_RESULT senders=(\d+) rts=(\d+) unique=(\d+) duplicates=(\d+) measure_us=(\d+)", text)
        cfg = re.search(r"warm_us=(\d+) measure_us=(\d+).*cycles_per_us=(\d+) burst=(\d+)", text)
        if (not m or not cfg or "TEST_FAIL " in text or "TEST_PASS hidden16 drained" not in text
                or (int(m[1]), int(m[2]), int(m[5])) != (n, int(rts), measure)
                or (int(cfg[1]), int(cfg[2]), int(cfg[4])) != (warm, measure, 0)):
            raise RuntimeError(f"missing/wrong measurement or drain: {log}")
        counts = re.findall(r"HIDDEN_SOURCE node=\d+ submitted=(\d+) completed=(\d+) unique=\d+", text)
        return {"platform": "RealEmu", "senders": n, "rts": rts, "seed": seed,
                "backoff_seed": models[seed - 1]["build_cases"][0]["defines"].get("REALEMU_BACKOFF_SEED", 12345),
                "warm_us": warm, "measure_us": measure, "unique": int(m[3]), "duplicates": int(m[4]),
                "mbps": int(m[3]) * 8000 / measure, "cycles_per_us": int(cfg[3]),
                "submitted_packets": sum(int(a) for a, _ in counts),
                "acked_packets_at_stop": sum(int(b) for _, b in counts),
                "drained": True, "seconds": seconds, "log": log}

    def parse_reference(text, n, rts, seed, seconds, log):
        m = re.search(r"NS3_RESULT total_nodes=16 senders=(\d+) rts=(\d+) run=(\d+) unique=(\d+) measure_us=(\d+) mbps=([\d.]+)", text)
        if not m or (int(m[1]), int(m[2]), int(m[3]), int(m[5])) != (n, int(rts), seed, measure):
            raise RuntimeError(f"wrong ns-3 result: {log}")
        return {"platform": "ns3", "senders": n, "rts": rts, "seed": seed,
                "warm_us": warm, "measure_us": measure, "unique": int(m[4]),
                "mbps": float(m[6]), "seconds": seconds, "log": log}

    def preserve_interrupted(log):
        if log.exists():
            if "TEST_FAIL " in log.read_text():
                raise RuntimeError(f"functional failure must be diagnosed before retry: {log}")
            attempt = 1
            while log.with_suffix(f".interrupted-{attempt}.log").exists():
                attempt += 1
            log.rename(log.with_suffix(f".interrupted-{attempt}.log"))

    def real(job):
        n, rts, seed, path = job
        log = out / f"real-n{n}-rts{int(rts)}-seed{seed}.log"
        if args.resume and log.exists() and "TEST_PASS hidden16 drained" in log.read_text():
            return parse_real(log.read_text(), n, rts, seed, None, log.name)
        preserve_interrupted(log)
        command = [str(path), f"+nodes{n:02d}",
                   *(["+rts"] if rts else []), *(["+long"] if args.long else [])]
        text, seconds = run(command, path.parent, log, args.timeout, env)
        return parse_real(text, n, rts, seed, seconds, log.name)

    def reference(job):
        n, rts, seed = job
        log = out / f"ns3-n{n}-rts{int(rts)}-run{seed}.log"
        if args.resume and log.exists() and "NS3_RESULT " in log.read_text():
            return parse_reference(log.read_text(), n, rts, seed, None, log.name)
        preserve_interrupted(log)
        text, seconds = run([str(binary), f"--senders={n}", f"--rts={int(rts)}", f"--run={seed}",
                             f"--warmUs={warm}", f"--measureUs={measure}"], out, log, args.timeout)
        return parse_reference(text, n, rts, seed, seconds, log.name)

    records = []
    def key(record):
        return record["platform"], record["senders"], record["rts"], record["seed"]

    if args.resume:
        for record in json.loads((out / "runs.json").read_text()) if (out / "runs.json").exists() else []:
            text = (out / record["log"]).read_text()
            parse = parse_real if record["platform"] == "RealEmu" else parse_reference
            parse(text, record["senders"], record["rts"], record["seed"], record["seconds"], record["log"])
            records.append(record)
    known = {key(r) for r in records}
    reused_sources = []
    for directory in args.reuse_from:
        directory = directory.resolve()
        old = json.loads((directory / "summary.json").read_text())
        assert (old["warm_us"], old["measure_us"]) == (warm, measure), "reuse window differs"
        assert old["ns3_head"] == ns3_head and old["ns3_source_sha256"] == digest(source), "reuse ns-3 differs"
        hashes = json.loads((directory / "ns3-library-hashes.json").read_text())["ns3_libraries"]
        assert hashes == library_hashes, "reuse ns-3 libraries differ"
        assert len(old["bsv_models"]) == len(models), "reuse seed count differs"
        for a, b in zip(old["bsv_models"], models):
            assert a["source_manifest"] == b["source_manifest"], "reuse production sources differ"
            assert a["build_cases"][0]["defines"] == b["build_cases"][0]["defines"], "reuse compiler defines differ"
            assert scenario_body(Path(a["path"]).parent / "TestHidden16.bsv") == b["scenario_body_sha256"], "reuse test scenario differs"
        reused_sources.append(str(directory))
        for record in json.loads((directory / "runs.json").read_text()):
            if (record["senders"], record["rts"]) not in jobs or key(record) in known:
                continue
            if record["platform"] == "ns3" and record["seed"] > args.ns3_runs:
                continue
            src = directory / record["log"]; dst = out / record["log"]
            parsed = (parse_real if record["platform"] == "RealEmu" else parse_reference)(
                src.read_text(), record["senders"], record["rts"], record["seed"], record["seconds"], dst.name)
            parsed["reused_from"] = str(src)
            shutil.copy2(src, dst); records.append(parsed); known.add(key(parsed))
    write_json(out / "reuse-validation.json", {"sources": reused_sources,
               "production_manifests_match": True, "compiler_defines_match": True,
               "test_body_excluding_argument_parser_matches": True, "ns3_libraries_match": True,
               "reused_records": sum(bool(r.get("reused_from")) for r in records)})
    write_runs(out, records)
    errors = []
    try:
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            pending = {pool.submit(reference, job): job for job in
                       [(n, r, seed) for n, r in jobs for seed in range(1, args.ns3_runs + 1)]
                       if ("ns3", *job) not in known}
            for future in as_completed(pending):
                try:
                    records.append(future.result()); write_runs(out, records)
                except Exception as error:
                    errors.append(str(error))
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            # Dense hidden-node cases usually take longer to drain. Launch them
            # first to avoid leaving only the longest runs at the end of a batch.
            real_jobs = sorted([(n, r, seed, p) for n, r in jobs for seed, p in enumerate(paths, 1)
                                if ("RealEmu", n, r, seed) not in known],
                               key=lambda j: (-j[0], j[1], j[2]))
            pending = {pool.submit(real, job): job for job in real_jobs}
            for future in as_completed(pending):
                try:
                    record = future.result(); records.append(record); write_runs(out, records)
                    print(f"RealEmu N={record['senders']} rts={int(record['rts'])} seed={record['seed']} {record['mbps']:.4f} Mbps (drained)", flush=True)
                except Exception as error:
                    errors.append(str(error)); print(str(error), flush=True)
    finally:
        write_runs(out, records)
        write_json(out / "errors.json", errors)
    if errors:
        raise RuntimeError(f"{len(errors)} failed runs; see errors.json and raw logs")
    assert len(records) == len(jobs) * (len(paths) + args.ns3_runs), "incomplete matrix"
    comparison = []
    for n, rts in jobs:
        real_values = [x["mbps"] for x in records if x["platform"] == "RealEmu" and x["senders"] == n and x["rts"] == rts]
        ns3_values = [x["mbps"] for x in records if x["platform"] == "ns3" and x["senders"] == n and x["rts"] == rts]
        a, b = statistics.median(real_values), statistics.median(ns3_values)
        comparison.append({"senders": n, "rts": int(rts), "real_mbps": a, "ns3_mbps": b,
                           "relative_error_pct": (a / b - 1) * 100,
                           "real_min": min(real_values), "real_max": max(real_values),
                           "ns3_min": min(ns3_values), "ns3_max": max(ns3_values)})
    with (out / "comparison.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(comparison[0])); writer.writeheader(); writer.writerows(comparison)
    real_summary = []
    for n in args.senders:
        row = {"senders": n, "warm_us": warm, "measure_us": measure, "real_seeds": len(paths)}
        for rts, label in [(False, "rts_off"), (True, "rts_on")]:
            values = [r for r in records if r["platform"] == "RealEmu" and r["senders"] == n and r["rts"] == rts]
            for field in ["unique", "mbps", "submitted_packets"]:
                a = [r[field] for r in values]
                row.update({f"{label}_{field}_median": statistics.median(a),
                            f"{label}_{field}_min": min(a), f"{label}_{field}_max": max(a)})
        real_summary.append(row)
    with (out / "realemu-summary.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(real_summary[0])); writer.writeheader(); writer.writerows(real_summary)
    manifest = {"warm_us": warm, "measure_us": measure, "total_nodes": 16,
                "ns3_runs": args.ns3_runs, "bsv_binaries": [str(p) for p in paths],
                "ns3_head": ns3_head,
                "ns3_source_sha256": hashlib.sha256((out / source.name).read_bytes()).hexdigest(),
                "bsv_models": models, "ns3_libraries": library_hashes,
                "reused_sources": reused_sources,
                "reused_records": sum(bool(r.get("reused_from")) for r in records),
                "compile_ns3": compile_cmd, "comparison": comparison}
    write_json(out / "ns3-library-hashes.json", {"ns3_libraries": library_hashes})
    (out / "summary.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(comparison, indent=2))


if __name__ == "__main__":
    main()
