#!/usr/bin/env bash
# Build the Docker image, convert it to an EIF, and record the PCRs.
# PCR0 is the measurement of the whole image -- it is what your KMS key policy
# pins against, and it changes on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -t cc-enclave:latest -f enclave/Dockerfile .
nitro-cli build-enclave --docker-uri cc-enclave:latest \
    --output-file enclave/app.eif | tee enclave/measurements.json

echo
echo "PCR0 (image measurement):"
python3 -c "import json;print(json.load(open('enclave/measurements.json'))['Measurements']['PCR0'])" \
    2>/dev/null || grep -A5 PCR0 enclave/measurements.json
echo
echo "Paste that into kms/enclave-key-policy.json before creating the key."
echo "EIF size drives cold-start time:"
ls -lh enclave/app.eif
