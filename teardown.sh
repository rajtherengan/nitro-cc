#!/usr/bin/env bash
# Delete everything provision.sh created. Run this the moment you are done.
#
# The instance is the only thing costing real money (~$0.19/hr), so it goes
# first and the script keeps going even if later steps fail.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/.stack" ] || { echo "no aws/.stack -- nothing to tear down"; exit 0; }
source "$HERE/.stack"

echo "Tearing down $NAME in $REGION"

echo "-> terminating instance ${INSTANCE:-none}"
if [ -n "${INSTANCE:-}" ]; then
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE" >/dev/null
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE"
fi

echo "-> security group"
# The ENI lingers briefly after termination; retry rather than fail.
for i in 1 2 3 4 5 6; do
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG" 2>/dev/null && break
    sleep 10
done

echo "-> key pair"
aws ec2 delete-key-pair --region "$REGION" --key-name "$KEYPAIR" >/dev/null 2>&1
rm -f "$HERE/$KEYPAIR.pem"

echo "-> iam"
aws iam remove-role-from-instance-profile \
    --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null
aws iam delete-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null
aws iam delete-role-policy --role-name "$ROLE" --policy-name kms 2>/dev/null
aws iam delete-role --role-name "$ROLE" 2>/dev/null

echo "-> kms (7-day pending window, minimum allowed)"
aws kms delete-alias --region "$REGION" --alias-name "alias/$NAME" 2>/dev/null
aws kms schedule-key-deletion --region "$REGION" --key-id "$KEY_ID" \
    --pending-window-in-days 7 --query 'DeletionDate' --output text 2>/dev/null

rm -f "$HERE/.stack"
echo
echo "Done. KMS keys cannot be deleted instantly -- yours is scheduled and"
echo "billing \$1/month until then. Verify nothing is left:"
echo "  aws ec2 describe-instances --region $REGION \\"
echo "    --filters Name=instance-state-name,Values=running,pending \\"
echo "    --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output table"
