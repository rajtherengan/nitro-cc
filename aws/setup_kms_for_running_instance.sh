#!/usr/bin/env bash
# Run from YOUR MACHINE, against an instance you launched by hand.
#
#   ./aws/setup_kms_for_running_instance.sh i-0d45c68efb7abc198
#
# provision.sh normally creates the KMS key and instance role at launch. If you
# launched from the console instead, the instance has no role and there is no
# key, so the enclave has nothing to call and no credentials to call it with.
# This backfills both. An instance profile CAN be attached while running --
# unlike --enclave-options, which is launch-only.
#
# The key is created permissive on purpose. You tighten it to PCR0 afterwards
# with tighten_key_policy.sh, once the image exists and has a measurement.
set -euo pipefail

INSTANCE="${1:?usage: setup_kms_for_running_instance.sh <instance-id>}"
REGION="${AWS_REGION:-us-east-1}"
NAME="${STACK_NAME:-nitro-cc}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STACK="$HERE/.stack"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "account $ACCOUNT, region $REGION, instance $INSTANCE"

# --------------------------------------------------------------------------- #
echo "==> KMS key"
if KEY_ID=$(aws kms describe-key --region "$REGION" --key-id "alias/$NAME" \
            --query KeyMetadata.KeyId --output text 2>/dev/null); then
    echo "reusing existing alias/$NAME -> $KEY_ID"
else
    KEY_ID=$(aws kms create-key --region "$REGION" \
        --description "$NAME enclave data key" \
        --query KeyMetadata.KeyId --output text)
    aws kms create-alias --region "$REGION" \
        --alias-name "alias/$NAME" --target-key-id "$KEY_ID"
    echo "created $KEY_ID (alias/$NAME)"
fi

# --------------------------------------------------------------------------- #
echo "==> IAM role and instance profile"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam create-role --role-name "$NAME-role" \
    --assume-role-policy-document "$TRUST" >/dev/null 2>&1 || echo "role exists"

aws iam put-role-policy --role-name "$NAME-role" --policy-name kms \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{
        \"Effect\":\"Allow\",
        \"Action\":[\"kms:Decrypt\",\"kms:Encrypt\",\"kms:GenerateDataKey\"],
        \"Resource\":\"arn:aws:kms:$REGION:$ACCOUNT:key/$KEY_ID\"}]}"

aws iam create-instance-profile --instance-profile-name "$NAME-profile" \
    >/dev/null 2>&1 || echo "profile exists"
aws iam add-role-to-instance-profile --instance-profile-name "$NAME-profile" \
    --role-name "$NAME-role" 2>/dev/null || true
sleep 10   # IAM propagation

# --------------------------------------------------------------------------- #
echo "==> attaching profile to $INSTANCE"
EXISTING=$(aws ec2 describe-iam-instance-profile-associations --region "$REGION" \
    --filters "Name=instance-id,Values=$INSTANCE" \
    --query 'IamInstanceProfileAssociations[0].AssociationId' --output text)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
    echo "replacing existing association $EXISTING"
    aws ec2 replace-iam-instance-profile-association --region "$REGION" \
        --association-id "$EXISTING" \
        --iam-instance-profile "Name=$NAME-profile" >/dev/null
else
    aws ec2 associate-iam-instance-profile --region "$REGION" \
        --instance-id "$INSTANCE" \
        --iam-instance-profile "Name=$NAME-profile" >/dev/null
fi

{ echo "REGION=$REGION"; echo "NAME=$NAME"; echo "KEY_ID=$KEY_ID"
  echo "ROLE=$NAME-role"; echo "PROFILE=$NAME-profile"
  echo "INSTANCE=$INSTANCE"; } > "$STACK"

cat <<EOF

Done. Wrote $STACK (teardown.sh will use it).

Credentials take ~30s to appear on the instance. Verify there:

  aws sts get-caller-identity        # should show .../$NAME-role/i-...

Then continue with Act 3 on the instance.
EOF
