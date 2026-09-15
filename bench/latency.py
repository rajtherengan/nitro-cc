#!/usr/bin/env python3
"""
Response-time harness.

    python3 bench/latency.py --url http://localhost:8080 --label enclave
    python3 bench/latency.py --url http://localhost:8081 --label baseline
    python3 bench/latency.py --compare http://localhost:8080 http://localhost:8081

Design choices that decide whether your numbers mean anything:

  * WARMUP is discarded. First requests pay Python import, TLS/TCP setup, page
    faults, and CPU frequency ramp. Include them and your "enclave overhead"
    is mostly interpreter startup.
  * Keep-alive connections, one per worker. Otherwise you measure connect().
  * Report p50/p90/p99, not the mean. Confidential computing costs show up in
    the tail (EPC pressure, vsock scheduling), and a mean hides that entirely.
  * Sweep payload size. Per-request overhead is roughly fixed, so at 1 record
    it dominates and at 10k records it disappears. A single payload size will
    tell you whatever story you wanted to hear.
  * Report server-side service_us alongside client-observed latency. The gap
    is your transport cost -- that is the number that is actually different
    between the two paths.
"""

from __future__ import annotations

import argparse
import base64
import json
import statistics
import sys
import threading
import time
import urllib.request
from http.client import HTTPConnection
from urllib.parse import urlparse

import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from common.workload import seal, synthetic_records  # noqa: E402

# In DEV_MODE both sides use the all-zero key. On AWS, scripts/05_make_data_key.sh
# writes the plaintext key here -- the parent is allowed to Encrypt, so it can
# seal test payloads; only the attested enclave can Decrypt the wrapped copy.
DATA_KEY = (base64.b64decode(os.environ["DATA_KEY_B64"])
            if os.environ.get("DATA_KEY_B64") else b"\x00" * 32)


def pct(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    k = (len(values) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def worker(url: str, payload: bytes, n: int, out: list, service: list) -> None:
    u = urlparse(url)
    conn = HTTPConnection(u.hostname, u.port, timeout=30)
    headers = {"Content-Type": "application/json", "Connection": "keep-alive"}
    lat, svc = [], []
    for _ in range(n):
        t0 = time.perf_counter()
        conn.request("POST", "/", body=payload, headers=headers)
        body = conn.getresponse().read()
        lat.append((time.perf_counter() - t0) * 1000)
        try:
            svc.append(json.loads(body).get("service_us", 0) / 1000)
        except json.JSONDecodeError:
            pass
    conn.close()
    out.extend(lat)
    service.extend(svc)


def run(url: str, records: int, requests: int, concurrency: int,
        warmup: int) -> dict:
    payload = json.dumps({
        "op": "aggregate",
        "envelope": seal(DATA_KEY, synthetic_records(records)),
    }).encode()

    # warmup, discarded
    if warmup:
        worker(url, payload, warmup, [], [])

    lat: list[float] = []
    svc: list[float] = []
    per = max(1, requests // concurrency)
    threads = [
        threading.Thread(target=worker, args=(url, payload, per, lat, svc))
        for _ in range(concurrency)
    ]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0

    lat.sort()
    svc.sort()
    return {
        "records": records,
        "n": len(lat),
        "rps": len(lat) / wall,
        "p50": pct(lat, 50), "p90": pct(lat, 90), "p99": pct(lat, 99),
        "mean": statistics.fmean(lat),
        "svc_p50": pct(svc, 50),
        "bytes": len(payload),
    }


def table(rows: list[dict], label: str) -> None:
    print(f"\n  {label}")
    print(f"  {'records':>8} {'payload':>9} {'p50 ms':>9} {'p90 ms':>9} "
          f"{'p99 ms':>9} {'svc p50':>9} {'req/s':>9}")
    print("  " + "-" * 68)
    for r in rows:
        print(f"  {r['records']:>8} {r['bytes']:>8}B {r['p50']:>9.3f} "
              f"{r['p90']:>9.3f} {r['p99']:>9.3f} {r['svc_p50']:>9.3f} "
              f"{r['rps']:>9.0f}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url")
    ap.add_argument("--compare", nargs=2, metavar=("ENCLAVE_URL", "BASELINE_URL"))
    ap.add_argument("--label", default="target")
    ap.add_argument("--requests", type=int, default=2000)
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--warmup", type=int, default=200)
    ap.add_argument("--sizes", default="1,10,100,1000",
                    help="records per request, comma separated")
    args = ap.parse_args()

    sizes = [int(s) for s in args.sizes.split(",")]

    if args.compare:
        enc_url, base_url = args.compare
        enc = [run(enc_url, s, args.requests, args.concurrency, args.warmup)
               for s in sizes]
        base = [run(base_url, s, args.requests, args.concurrency, args.warmup)
                for s in sizes]
        table(base, "BASELINE  (plain process on the parent instance)")
        table(enc, "ENCLAVE   (Nitro Enclave over vsock)")
        print("\n  DELTA")
        print(f"  {'records':>8} {'p50 abs':>10} {'p50 rel':>9} "
              f"{'p99 abs':>10} {'p99 rel':>9}")
        print("  " + "-" * 50)
        for b, e in zip(base, enc):
            print(f"  {b['records']:>8} {e['p50'] - b['p50']:>+9.3f}ms "
                  f"{e['p50'] / b['p50']:>8.2f}x {e['p99'] - b['p99']:>+9.3f}ms "
                  f"{e['p99'] / b['p99']:>8.2f}x")
        print("\n  Fixed per-request overhead should be roughly constant in the")
        print("  absolute column and shrink toward 1.00x as payloads grow. If")
        print("  the relative column stays flat, you are CPU-bound, not")
        print("  transport-bound, and the enclave is not your problem.")
    else:
        rows = [run(args.url, s, args.requests, args.concurrency, args.warmup)
                for s in sizes]
        table(rows, args.label)
    print()


if __name__ == "__main__":
    main()
