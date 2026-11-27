"""Compare complete retire traces and IPC under identical cache and memory settings."""
import argparse
import csv
import filecmp
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from statistics import geometric_mean

ROOT = Path(__file__).resolve().parents[2]
CONFIGS = ("graded", "default", "small", "large")
COURSE = {name: ROOT / f"traces/{name}_program.hex" for name in ("random", "hazard", "no_hazard")}
PROGRAMS = {**COURSE, **{p.stem: p for p in sorted((ROOT / "traces/bench").glob("*.hex"))}}
TRAPS = {name: ROOT / f"traces/directed/{name}.hex" for name in ("traps", "trap_jump")}


def simulate(source, directory, config, latency, program):
    directory.mkdir()
    rtl = sorted(p for p in source.glob("*.v") if not p.name.endswith("_tb.v"))
    sim = directory / "sim"
    trace = directory / "retire.trace"
    image = TRAPS[program] if program in TRAPS else PROGRAMS[program]
    args = ["iverilog", "-g2005", "-s", "bench_tb", "-I", str(ROOT),
            f"-DBENCH_CONFIG=`HART_CFG_{config.upper()}", f"-Pbench_tb.LATENCY={latency}",
            f"-Pbench_tb.TRAPS_OK={int(program in TRAPS)}",
            f'-Pbench_tb.PROGRAM="{image.relative_to(ROOT)}"', "-o", str(sim),
            ROOT / "tools/bench/bench_tb.v", *rtl, *sorted((source / "cache").glob("*.v"))]
    subprocess.run(args, cwd=ROOT, check=True)
    run = subprocess.run(["vvp", "-n", sim, f"+trace={trace}"], cwd=ROOT,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    match = re.search(r"^MEASURE (\d+) (\d+)$", run.stdout, re.M)
    if run.returncode or not match:
        raise RuntimeError(f"{program} {config} lat{latency} {source}\n{run.stdout}")
    return tuple(map(int, match.groups())), trace


def compare(case, current):
    config, latency, program = case
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (n, old), ref = simulate(ROOT / "baseline/phase7", root / "old", *case)
        (m, new), got = simulate(current, root / "new", *case)
        if n != m or not filecmp.cmp(ref, got, shallow=False):
            with ref.open() as a, got.open() as b:
                first = next((i for i, (x, y) in enumerate(zip(a, b), 1) if x != y), min(n, m) + 1)
            raise RuntimeError(f"{case}: retire trace differs at instruction {first} (counts {n}, {m})")
    return (config, latency, program, n, old, new, f"{n / old:.4f}", f"{n / new:.4f}",
            f"{100 * (old / new - 1):.2f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full", action="store_true", help="all four caches at latencies 1, 4 and 10")
    parser.add_argument("--program", action="append", choices=[*PROGRAMS, *TRAPS])
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--current", type=Path, default=ROOT)
    args = parser.parse_args()
    settings = ([(c, l) for c in CONFIGS for l in (1, 4, 10)] if args.full
                else [("graded", 4), ("default", 1)])
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(("cache", "latency", "program", "retired", "phase7_cycles", "phase8_cycles",
                     "phase7_ipc", "phase8_ipc", "gain_percent"))
    cases = [(c, l, p) for c, l in settings for p in (args.program or PROGRAMS)]
    ratios = {s: [] for s in settings}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for row in pool.map(lambda case: compare(case, args.current.resolve()), cases):
            writer.writerow(row)
            sys.stdout.flush()
            ratios[row[:2]].append(row[4] / row[5])
    for (config, latency), values in ratios.items():
        print(f"{config} lat{latency} geometric mean IPC gain: {100 * (geometric_mean(values) - 1):+.2f}%",
              file=sys.stderr)


if __name__ == "__main__":
    main()
