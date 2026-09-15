#!/usr/bin/env bash
# Run this BEFORE provision.sh. Checks everything that commonly fails halfway
# through provisioning and leaves you with half a stack to clean up manually.
#
#   ./aws/preflight.sh
#
# Read-only: creates nothing, costs nothing.
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }

echo
echo "Preflight for region $REGION"
echo

# --- tooling ---------------------------------------------------------------
command -v aws >/dev/null && ok "aws cli $(aws --version 2>&1 | cut -d' ' -f1)" \
    || bad "aws cli missing -- https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
command -v jq  >/dev/null && ok "jq present" || bad "jq missing (brew/apt install jq)"
command -v ssh >/dev/null && ok "ssh present" || bad "ssh missing"
command -v rsync >/dev/null && ok "rsync present" || warn "rsync missing (needed to copy the project up; scp works too)"

# --- identity --------------------------------------------------------------
if ID=$(aws sts get-caller-identity --output json 2>/dev/null); then
    ARN=$(echo "$ID" | jq -r .Arn)
    ok "authenticated as $ARN"
    case "$ARN" in
      *":root") warn "these are ROOT credentials. Create an IAM user or use IAM Identity Center instead." ;;
    esac
else
    bad "no working credentials -- run 'aws configure' (see README)"
    echo; echo "Stopping: nothing else can be checked."; exit 1
fi

# --- permissions (dry-run / read-only probes) ------------------------------
probe() { # probe <label> <command...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label -- missing permission"; fi
}
probe "ec2:DescribeInstances"  aws ec2 describe-instances --region "$REGION" --max-items 1
probe "ec2:DescribeVpcs"       aws ec2 describe-vpcs --region "$REGION"
probe "ec2:DescribeImages/SSM" aws ssm get-parameters --region "$REGION" \
      --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64
probe "iam:ListRoles"          aws iam list-roles --max-items 1
probe "kms:ListKeys"           aws kms list-keys --region "$REGION" --limit 1

# RunInstances is the one that really matters and cannot be probed read-only,
# so use the API's own dry-run.
if OUT=$(aws ec2 run-instances --region "$REGION" --dry-run \
        --image-id ami-00000000000000000 --instance-type m5.xlarge 2>&1); then :; fi
case "$OUT" in
  *DryRunOperation*)      ok  "ec2:RunInstances (dry-run accepted)" ;;
  *InvalidAMIID*)         ok  "ec2:RunInstances (reached AMI validation -- permission fine)" ;;
  *UnauthorizedOperation*) bad "ec2:RunInstances -- permission denied" ;;
  *)                      warn "ec2:RunInstances inconclusive: $(echo "$OUT" | head -1)" ;;
esac

# --- default VPC -----------------------------------------------------------
VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
[ "$VPC" != "None" ] && [ -n "$VPC" ] && ok "default VPC $VPC" \
    || bad "no default VPC in $REGION -- provision.sh assumes one exists"

# --- vCPU quota ------------------------------------------------------------
# m5.xlarge needs 4 vCPUs of Standard on-demand headroom. Brand new accounts
# are sometimes capped low, and RunInstances then fails with VcpuLimitExceeded.
QUOTA=$(aws service-quotas get-service-quota --region "$REGION" \
        --service-code ec2 --quota-code L-1216C47A \
        --query 'Quota.Value' --output text 2>/dev/null)
if [ -n "$QUOTA" ] && [ "$QUOTA" != "None" ]; then
    if [ "${QUOTA%.*}" -ge 4 ]; then ok "Standard on-demand vCPU quota: ${QUOTA%.*}"
    else bad "vCPU quota is ${QUOTA%.*}, need >=4 -- request an increase in Service Quotas"; fi
else
    warn "could not read vCPU quota (servicequotas:GetServiceQuota not granted)"
fi

# --- enclave-capable instance available in this region ---------------------
if aws ec2 describe-instance-types --region "$REGION" \
    --instance-types m5.xlarge --query 'InstanceTypes[0].InstanceType' \
    --output text 2>/dev/null | grep -q m5.xlarge; then
    ok "m5.xlarge offered in $REGION"
else
    warn "m5.xlarge not confirmed in $REGION -- try c5.xlarge or another region"
fi

# --- budget guard ----------------------------------------------------------
N=$(aws budgets describe-budgets --account-id "$(echo "$ID" | jq -r .Account)" \
    --query 'length(Budgets)' --output text 2>/dev/null)
if [ "${N:-0}" = "0" ] || [ "$N" = "None" ]; then
    warn "no AWS Budget configured. Set one before launching -- a forgotten m5.xlarge is ~\$140/month."
else
    ok "$N budget(s) configured"
fi

echo
[ "$FAIL" = "0" ] && echo "Preflight passed. Run ./aws/provision.sh" \
                  || echo "Preflight FAILED. Fix the items above first."
exit "$FAIL"
