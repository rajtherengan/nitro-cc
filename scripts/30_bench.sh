#!/usr/bin/env bash
# Steady-state response time, both paths, same box.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 parent/baseline_server.py & BASE=$!
trap 'kill $BASE 2>/dev/null' EXIT
sleep 2

# Pin the load generator to CPUs the allocator did NOT take, so the client
# isn't fighting the gateway for the parent's remaining cores.
python3 bench/latency.py \
    --compare http://localhost:8080 http://localhost:8081 \
    --requests "${REQUESTS:-5000}" \
    --concurrency "${CONCURRENCY:-8}" \
    --warmup 500 \
    --sizes 1,10,100,1000,10000 | tee "bench/results_$(date +%Y%m%d_%H%M).txt"
