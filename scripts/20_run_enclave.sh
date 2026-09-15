#!/usr/bin/env bash
# Launch the enclave + the KMS vsock proxy + the parent gateway.
#
# DEBUG NOTE: --debug-mode gives you `nitro-cli console` but ZEROES ALL PCRs.
# Your KMS policy will then reject the enclave. Debug and attest are mutually
# exclusive; expect to toggle.
set -euo pipefail
cd "$(dirname "$0")/.."

DEBUG=${DEBUG:-0}
EXTRA=""
[ "$DEBUG" = "1" ] && EXTRA="--debug-mode"

nitro-cli terminate-enclave --all >/dev/null 2>&1 || true

nitro-cli run-enclave \
    --eif-path enclave/app.eif \
    --cpu-count 2 \
    --memory 3072 \
    --enclave-cid 16 \
    $EXTRA

# The enclave has NO network. This proxy is its only route to KMS, and it is
# the reason kms:Decrypt latency lands in the 40-150ms range rather than ~5ms.
sudo systemctl enable --now nitro-enclaves-vsock-proxy.service 2>/dev/null || \
    (vsock-proxy 8000 "kms.${AWS_REGION:-us-east-1}.amazonaws.com" 443 &)

sleep 3
[ "$DEBUG" = "1" ] && echo "console: nitro-cli console --enclave-id \$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveID')"

TRANSPORT=vsock ENCLAVE_CID=16 \
    WRAPPED_DATA_KEY="$(cat kms/wrapped_key.b64 2>/dev/null || echo '')" \
    python3 parent/gateway.py
