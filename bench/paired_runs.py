#!/usr/bin/env python3
"""
Paired, order-randomised latency runs for the revision of paper 1571355379.

Each *pair* is one enclave run and one baseline run, executed back to back in
a random order. Each *run* sweeps every payload size once, using the same
measurement procedure as bench/latency.py (warmup discarded, keep-alive
connections, closed loop). One CSV row is written per (pair, target, size)
and flushed immediately, so an interrupted session keeps every finished run.

    python3 bench/paired_runs.py --pairs 25 --out bench/paired_$(date +%Y%m%d_%H%M).csv

Defaults match the paper: concurrency 4, 300 warmup, 3000 measured requests,
sizes 1..10000. Run it via scripts/35_bench_paired.sh, which pins this process
and the baseline server to the parent's CPUs.
"""

from __future__ import annotations

import argparse
import csv
import os
import random
import sys
import time
import urllib.request
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from latency import run  # noqa: E402  (same procedure as the original runs)

FIELDS = ["run", "target", "order", "records", "bytes", "n", "p50", "p90",
          "p99", "mean", "svc_p50", "rps", "started_utc"]


def healthy(url: str) -> bool:
    try:
        return urllib.request.urlopen(url, timeout=5).status == 200
    except Exception:  # noqa: BLE001
        return False


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", type=int, default=25)
    ap.add_argument("--enclave-url", default="http://localhost:8080")
    ap.add_argument("--baseline-url", default="http://localhost:8081")
    ap.add_argument("--sizes", default="1,10,100,1000,10000")
    ap.add_argument("--requests", type=int, default=3000)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--warmup", type=int, default=300)
    ap.add_argument("--seed", type=int, default=20261014,
                    help="seed for the run order, recorded for reproducibility")
    ap.add_argument("--pause", type=float, default=2.0,
                    help="seconds to idle between runs")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if not os.environ.get("DATA_KEY_B64"):
        sys.exit("DATA_KEY_B64 is not set: export DATA_KEY_B64=$(cat kms/plaintext_key.b64)")
    urls = {"enclave": args.enclave_url, "baseline": args.baseline_url}
    for name, url in urls.items():
        if not healthy(url):
            sys.exit(f"{name} at {url} is not answering; start it first")

    sizes = [int(s) for s in args.sizes.split(",")]
    rng = random.Random(args.seed)
    t_start = time.time()

    with open(args.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS)
        w.writeheader()
        for pair in range(1, args.pairs + 1):
            order = ["enclave", "baseline"]
            rng.shuffle(order)
            for pos, target in enumerate(order, start=1):
                started = datetime.now(timezone.utc).isoformat(timespec="seconds")
                for size in sizes:
                    r = run(urls[target], size, args.requests,
                            args.concurrency, args.warmup)
                    w.writerow({
                        "run": pair, "target": target, "order": pos,
                        "records": size, "bytes": r["bytes"], "n": r["n"],
                        "p50": f"{r['p50']:.4f}", "p90": f"{r['p90']:.4f}",
                        "p99": f"{r['p99']:.4f}", "mean": f"{r['mean']:.4f}",
                        "svc_p50": f"{r['svc_p50']:.4f}", "rps": f"{r['rps']:.0f}",
                        "started_utc": started,
                    })
                    fh.flush()
                time.sleep(args.pause)
            done = time.time() - t_start
            eta = done / pair * (args.pairs - pair)
            print(f"pair {pair:>3}/{args.pairs}  order={'/'.join(order)}  "
                  f"elapsed {done/60:5.1f} min  eta {eta/60:5.1f} min", flush=True)

    print(f"\nwrote {args.out}  (seed {args.seed})")


if __name__ == "__main__":
    main()
