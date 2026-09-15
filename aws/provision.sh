#!/usr/bin/env bash
# Provision everything needed to run the enclave benchmark. Run from YOUR
# machine (laptop), not from EC2.
#
#   ./aws/provision.sh
#
# Creates: KMS key, IAM role + instance profile, security group locked to your
# current public IP, SSH key pair, and one enclave-enabled m5.xlarge.
# Every resource ID is written to aws/.stack so teardown.sh can remove them.
#
# COST: m5.xlarge is ~$0.19/hr and is NOT free tier. KMS is $1/month per key.
# Run ./aws/teardown.sh when you are done. A forgotten instance is ~$140/month.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
NAME="${STACK_NAME:-nitro-cc}"
INSTANCE_TYPE="${INSTANCE_TYPE:-m5.xlarge}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STACK="$HERE/.stack"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
record() { echo "$1=$2" >> "$STACK"; }

# --------------------------------------------------------------------------- #
say "Preflight"
command -v aws >/dev/null || { echo "aws cli not installed"; exit 1; }
command -v jq  >/dev/null || { echo "jq not installed"; exit 1; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "account $ACCOUNT, region $REGION, type $INSTANCE_TYPE"

if [ -f "$STACK" ]; then
    echo "aws/.stack already exists -- a stack may be running."
    echo "Run ./aws/teardown.sh first, or delete the file if you know it is stale."
    exit 1
fi
: > "$STACK"
record REGION "$REGION"
record NAME "$NAME"

# --------------------------------------------------------------------------- #
say "KMS key"
# Created permissive. You TIGHTEN it to the PCR0 condition after the first
# enclave build, using tighten_key_policy.sh. Chicken-and-egg: the measurement
# does not exist until the image is built.
KEY_ID=$(aws kms create-key --region "$REGION" \
    --description "$NAME enclave data key" \
    --tags TagKey=Name,TagValue="$NAME" \
    --query KeyMetadata.KeyId --output text)
aws kms create-alias --region "$REGION" \
    --alias-name "alias/$NAME" --target-key-id "$KEY_ID"
record KEY_ID "$KEY_ID"
echo "key $KEY_ID (alias/$NAME)"

# --------------------------------------------------------------------------- #
say "IAM role and instance profile"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$NAME-role" \
    --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$NAME-role" --policy-name kms \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{
        \"Effect\":\"Allow\",
        \"Action\":[\"kms:Decrypt\",\"kms:Encrypt\",\"kms:GenerateDataKey\"],
        \"Resource\":\"arn:aws:kms:$REGION:$ACCOUNT:key/$KEY_ID\"}]}"
aws iam create-instance-profile --instance-profile-name "$NAME-profile" >/dev/null
aws iam add-role-to-instance-profile \
    --instance-profile-name "$NAME-profile" --role-name "$NAME-role"
record ROLE "$NAME-role"
record PROFILE "$NAME-profile"
echo "waiting 15s for IAM propagation (run-instances fails without this)"
sleep 15

# --------------------------------------------------------------------------- #
say "Security group"
VPC=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$NAME-sg" --description "$NAME ssh" --vpc-id "$VPC" \
    --query GroupId --output text)
MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG" --protocol tcp --port 22 --cidr "$MYIP/32" >/dev/null
record SG "$SG"
echo "sg $SG, ssh open to $MYIP/32 only"

# --------------------------------------------------------------------------- #
say "SSH key pair"
aws ec2 create-key-pair --region "$REGION" --key-name "$NAME-key" \
    --query KeyMaterial --output text > "$HERE/$NAME-key.pem"
chmod 400 "$HERE/$NAME-key.pem"
record KEYPAIR "$NAME-key"
echo "private key at aws/$NAME-key.pem"

# --------------------------------------------------------------------------- #
say "Launching instance"
AMI=$(aws ssm get-parameters --region "$REGION" \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 \
    --query 'Parameters[0].Value' --output text)
echo "ami $AMI"

INSTANCE=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$NAME-key" \
    --security-group-ids "$SG" \
    --iam-instance-profile "Name=$NAME-profile" \
    --enclave-options Enabled=true \
    --block-device-mappings \
        'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
    --user-data "file://$HERE/bootstrap-userdata.sh" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Instances[0].InstanceId' --output text)
record INSTANCE "$INSTANCE"

echo "waiting for $INSTANCE to run..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE"
IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
record IP "$IP"

# --------------------------------------------------------------------------- #
say "Done"
cat <<EOF
instance  $INSTANCE  ($INSTANCE_TYPE, enclaves enabled)
public ip $IP
kms key   alias/$NAME

Bootstrap (nitro-cli, docker, allocator) is still running via user-data.
Give it ~2 minutes, then:

  # copy the project up
  rsync -az -e "ssh -i aws/$NAME-key.pem -o StrictHostKeyChecking=accept-new" \\
      --exclude aws --exclude '*.pem' ./ ec2-user@$IP:~/nitro-cc/

  ssh -i aws/$NAME-key.pem ec2-user@$IP
  tail -f /var/log/cloud-init-output.log     # wait for BOOTSTRAP COMPLETE
  cd nitro-cc && ./scripts/10_build_enclave.sh

Then take the printed PCR0 and, back on your machine:

  ./aws/tighten_key_policy.sh <PCR0>

TEARDOWN WHEN FINISHED:  ./aws/teardown.sh
EOF
