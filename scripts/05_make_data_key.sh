#!/usr/bin/env bash
# Run ON THE INSTANCE, after the KMS policy is tightened.
#
# GenerateDataKey hands back two things: the plaintext key and a wrapped copy.
# They go to different places, and the split is the point:
#
#   wrapped copy  -> baked into the enclave's init message. Only an enclave
#                    whose PCR0 matches can unwrap it.
#   plaintext key -> stays on the parent purely so the BENCHMARK CLIENT can
#                    seal fake test payloads. In a real deployment the parent
#                    never sees this; the hospitals hold it and the parent only
#                    ever relays ciphertext.
set -euo pipefail
cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-us-east-1}"
ALIAS="${KMS_ALIAS:-alias/nitro-cc}"

OUT=$(aws kms generate-data-key --region "$REGION" \
        --key-id "$ALIAS" --key-spec AES_256)

mkdir -p kms
echo "$OUT" | jq -r .CiphertextBlob > kms/wrapped_key.b64
echo "$OUT" | jq -r .Plaintext      > kms/plaintext_key.b64
chmod 600 kms/plaintext_key.b64

echo "wrapped key  -> kms/wrapped_key.b64   (safe to hand to the enclave)"
echo "plaintext    -> kms/plaintext_key.b64 (test client only; never ship this)"
echo
echo "Export it before benchmarking:"
echo "  export DATA_KEY_B64=\$(cat kms/plaintext_key.b64)"
echo
echo "Sanity check that attestation is actually enforced -- this SHOULD fail"
echo "with AccessDenied once the policy is tightened:"
echo "  aws kms decrypt --region $REGION \\"
echo "    --ciphertext-blob fileb://<(base64 -d kms/wrapped_key.b64)"
