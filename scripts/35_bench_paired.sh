#!/usr/bin/env bash
# Paired, order-randomised steady-state latency runs (paper revision).
#
# Prerequisites, same as the original controlled runs:
#   * enclave + vsock proxy + gateway running (scripts/20_run_enclave.sh),
#     enclave NOT in debug mode, gateway answering on :8080
#   * export DATA_KEY_B64=$(cat kms/plaintext_key.b64)
#   * the latency runs used a build with the KMS call stubbed; use that same
#     build so the new numbers are comparable with the paper's
#
# CPU placement
#   Default (same as the paper, m5.xlarge): baseline server, load generator and
#   gateway all share the parent's online vCPUs.
#   Separated (recommended on m5.2xlarge or larger): give the baseline its own
#   two vCPUs, like the enclave, and keep the client and gateway elsewhere:
#   e.g. on m5.2xlarge, if `nitro-cli describe-enclaves` shows CPUIDs [1, 5]:
#     BASELINE_CPUS=2,6 CLIENT_CPUS=0,3,4,7 PAIRS=25 ./scripts/35_bench_paired.sh
#   Check `lscpu -e` first and give the baseline two vCPUs on one physical
#   core (same CORE value), mirroring the enclave's allocation.
#
#   PAIRS=25 ./scripts/35_bench_paired.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PAIRS="${PAIRS:-25}"
PARENT_CPUS="${PARENT_CPUS:-$(cat /sys/devices/system/cpu/online)}"
BASELINE_CPUS="${BASELINE_CPUS:-$PARENT_CPUS}"
CLIENT_CPUS="${CLIENT_CPUS:-$PARENT_CPUS}"
OUT="bench/paired_$(date +%Y%m%d_%H%M).csv"
LOG="${OUT%.csv}.env.txt"

: "${DATA_KEY_B64:?export DATA_KEY_B64=\$(cat kms/plaintext_key.b64) first}"

# Record the environment next to the results (the paper's reproducibility
# section and the response letter will want these).
{
  echo "date_utc: $(date -u +%FT%TZ)"
  echo "instance_type: $(curl -s -m 2 -H "X-aws-ec2-metadata-token: $(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/instance-type || echo unknown)"
  echo "kernel: $(uname -r)"
  echo "parent_cpus: $PARENT_CPUS"
  echo "baseline_cpus: $BASELINE_CPUS"
  echo "client_and_gateway_cpus: $CLIENT_CPUS"
  echo "enclave: $(nitro-cli describe-enclaves 2>/dev/null | tr -d '\n' | tr -s ' ')"
  echo "lscpu_topology:"; lscpu -e=CPU,CORE,SOCKET,ONLINE 2>/dev/null || true
  echo "python: $(python3 --version 2>&1)"
  echo "git_commit: $(git rev-parse --short HEAD 2>/dev/null || echo none)"
  echo "pairs: $PAIRS"
} > "$LOG"

curl -sf -m 5 http://localhost:8080/ >/dev/null || {
  echo "gateway not answering on :8080 -- run scripts/20_run_enclave.sh first"; exit 1; }

# Keep the gateway off the baseline's CPUs when they are separated.
for pid in $(pgrep -f parent/gateway.py || true); do taskset -apc "$CLIENT_CPUS" "$pid" >/dev/null; done

taskset -c "$BASELINE_CPUS" python3 parent/baseline_server.py & BASE=$!
trap 'kill $BASE 2>/dev/null || true' EXIT
for _ in $(seq 20); do curl -sf -m 1 http://localhost:8081/ >/dev/null && break; sleep 0.5; done

echo "baseline CPUs: $BASELINE_CPUS   client/gateway CPUs: $CLIENT_CPUS   pairs: $PAIRS   output: $OUT"
taskset -c "$CLIENT_CPUS" python3 bench/paired_runs.py --pairs "$PAIRS" --out "$OUT"

echo
echo "Done. Analyse with:"
echo "  python3 bench/analyze_paired.py $OUT"
