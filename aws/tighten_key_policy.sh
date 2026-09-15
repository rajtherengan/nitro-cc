#!/usr/bin/env bash
# Lock the KMS key to one specific enclave image.
#
#   ./aws/tighten_key_policy.sh <PCR0>
#
# Before this runs, the instance role can decrypt normally -- convenient, but
# it means root on the parent can read your data, which is the entire thing you
# are trying to prevent. After it runs, kms:Decrypt succeeds ONLY for calls
# carrying an attestation document whose PCR0 matches. Root on the parent still
# holds the credentials and still cannot decrypt.
#
# Verify it worked by trying to decrypt from the parent shell -- you should get
# AccessDenied. If you don't, the condition didn't apply.
set -euo pipefail

PCR0="${1:?usage: tighten_key_policy.sh <PCR0>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/.stack"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AdminManagesKeyButCannotUseIt",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::$ACCOUNT:root" },
      "Action": ["kms:Describe*", "kms:List*", "kms:Get*", "kms:Put*",
                 "kms:Update*", "kms:Revoke*", "kms:Disable*", "kms:Enable*",
                 "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
                 "kms:CreateAlias", "kms:DeleteAlias", "kms:TagResource"],
      "Resource": "*"
    },
    {
      "Sid": "ParentEncryptsOnly",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::$ACCOUNT:role/$ROLE" },
      "Action": ["kms:Encrypt", "kms:GenerateDataKey"],
      "Resource": "*"
    },
    {
      "Sid": "DecryptOnlyInsideTheAttestedEnclave",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::$ACCOUNT:role/$ROLE" },
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": {
        "StringEqualsIgnoreCase": {
          "kms:RecipientAttestation:PCR0": "$PCR0"
        }
      }
    }
  ]
}
JSON
)

aws kms put-key-policy --region "$REGION" --key-id "$KEY_ID" \
    --policy-name default --policy "$POLICY"

echo "Key $KEY_ID now gated on PCR0=$PCR0"
echo
echo "Reminder: --debug-mode zeroes all PCRs, so a debug enclave will now be"
echo "rejected by KMS. Rebuild without it, or re-run this with the zeroed PCR0"
echo "while debugging (never in anything real)."
