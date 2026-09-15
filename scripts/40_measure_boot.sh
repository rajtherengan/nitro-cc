#!/usr/bin/env bash
# Cold start: EIF load -> kernel boot -> app listening -> first response.
# Report this SEPARATELY from steady-state latency. It is seconds, not
# milliseconds, and averaging it into per-request numbers is the fastest way
# to publish a wrong result.
set -euo pipefail
cd "$(dirname "$0")/.."
N=${N:-5}

for i in $(seq 1 "$N"); do
    nitro-cli terminate-enclave --all >/dev/null 2>&1 || true
    sleep 2
    START=$(date +%s.%N)
    nitro-cli run-enclave --eif-path enclave/app.eif --cpu-count 2 \
        --memory 3072 --enclave-cid 16 >/dev/null
    until TRANSPORT=vsock ENCLAVE_CID=16 python3 -c "
import socket,sys
s=socket.socket(socket.AF_VSOCK,socket.SOCK_STREAM); s.settimeout(1)
try: s.connect((16,5005)); sys.exit(0)
except Exception: sys.exit(1)" 2>/dev/null; do sleep 0.05; done
    END=$(date +%s.%N)
    echo "run $i: $(echo "$END - $START" | bc) s to first accept"
done
