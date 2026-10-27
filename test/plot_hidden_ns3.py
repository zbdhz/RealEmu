#!/usr/bin/env python3
"""Render comparison.csv without changing or normalizing measured throughput."""
import argparse
import csv
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("comparison", type=Path)
    parser.add_argument("--output", type=Path,
                        help="write figures here; default is the CSV directory")
    args = parser.parse_args()
    with args.comparison.open() as stream:
        rows = [{key: float(value) for key, value in row.items()}
                for row in csv.DictReader(stream)]
    summary = args.comparison.with_name("summary.json")
    if summary.exists():
        metadata = json.loads(summary.read_text())
        seed_count = len(metadata["bsv_binaries"])
        ns3_runs = metadata["ns3_runs"]
    else:
        # Committed CSV snapshots omit machine-specific build paths and raw JSON.
        metadata = json.loads(args.comparison.with_name("manifest.json").read_text())
        seed_count = len(metadata["backoff_seeds"])
        ns3_runs = metadata["ns3_runs_per_condition"]
    run_json = args.comparison.with_name("runs.json")
    if run_json.exists():
        runs = json.loads(run_json.read_text())
    else:
        with args.comparison.with_name("runs.csv").open() as stream:
            runs = list(csv.DictReader(stream))
    clocks = sorted({int(row["cycles_per_us"]) for row in runs if row["platform"] == "RealEmu"})
    output = args.output or args.comparison.parent
    output.mkdir(parents=True, exist_ok=True)
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.5), sharey=True)
    for rts, ax in enumerate(axes):
        values = sorted((row for row in rows if row["rts"] == rts), key=lambda row: row["senders"])
        x = [row["senders"] for row in values]
        for name, prefix, color, marker in [("ns-3", "ns3", "#455a64", "s"),
                                             ("RealEmu", "real", "#1976d2", "o")]:
            median = [row[f"{prefix}_mbps"] for row in values]
            low = [row[f"{prefix}_min"] for row in values]
            high = [row[f"{prefix}_max"] for row in values]
            ax.plot(x, median, marker=marker, color=color, linewidth=2, label=name)
            ax.fill_between(x, low, high, color=color, alpha=0.13)
        ax.set_title(f"RTS/CTS {'on' if rts else 'off'}")
        ax.set_xlabel("Hidden senders (16 nodes total)")
        ax.set_xticks(x)
        ax.grid(alpha=0.25)
        ax.legend(frameon=False)
    axes[0].set_ylabel("Received unique payload goodput (Mbps)")
    axes[0].set_ylim(bottom=0)
    clock_label = "/".join(map(str, clocks))
    fig.suptitle(f"1064-byte PSDU / DATA 54 Mbps / control 6 Mbps / RealEmu {clock_label} cycles/us")
    caption = (f"{metadata['warm_us'] / 1000:g} ms warmup + {metadata['measure_us'] / 1000:g} ms measurement; "
               f"RealEmu {seed_count} seeds, ns-3 {ns3_runs} runs; "
               "bands: observed ranges (not confidence intervals)")
    fig.text(0.5, 0.015, caption,
             ha="center", fontsize=8)
    fig.tight_layout(rect=(0, 0.04, 1, 0.95))
    for suffix in [".png", ".svg"]:
        path = output / ("hidden-node-comparison" + suffix)
        fig.savefig(path, dpi=180)
        print(path)

    # A separate RealEmu figure makes the RTS gain readable without four curves.
    fig_real, ax = plt.subplots(figsize=(8, 4.8))
    for rts, color, marker in [(0, "#d55e00", "o"), (1, "#0072b2", "s")]:
        values = sorted((row for row in rows if row["rts"] == rts), key=lambda row: row["senders"])
        x = [row["senders"] for row in values]
        ax.plot(x, [row["real_mbps"] for row in values], color=color, marker=marker,
                linewidth=2, label=f"RTS/CTS {'on' if rts else 'off'}")
        ax.fill_between(x, [row["real_min"] for row in values],
                        [row["real_max"] for row in values], color=color, alpha=0.13)
    ax.set(xlabel="Hidden senders (center excluded; 16 nodes total)",
           ylabel="Received unique payload goodput (Mbps)",
           title=f"RealEmu / 1064-byte PSDU / {clock_label} cycles/us", ylim=(0, None))
    ax.set_xticks(sorted({row["senders"] for row in rows}))
    ax.grid(alpha=0.25); ax.legend(frameon=False)
    fig_real.text(0.5, 0.015,
                  f"{metadata['measure_us'] / 1000:g} ms measurement / {seed_count} seeds; median and observed range",
                  ha="center", fontsize=8)
    fig_real.tight_layout(rect=(0, 0.04, 1, 1))
    for suffix in [".png", ".svg"]:
        path = output / ("realemu-throughput" + suffix)
        fig_real.savefig(path, dpi=180)
        print(path)


if __name__ == "__main__":
    main()
