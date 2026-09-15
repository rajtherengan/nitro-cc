#!/bin/bash
# Runs as root on first boot, via EC2 user-data.
# Progress lands in /var/log/cloud-init-output.log -- tail that, don't guess.
set -euxo pipefail

dnf update -y
dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel \
               docker git python3-pip jq bc rsync
pip3 install --no-input cryptography

usermod -aG ne ec2-user
usermod -aG docker ec2-user

# Reserve resources for the enclave. The parent genuinely loses these: an
# m5.xlarge has 4 vCPU, so the parent is left with 2 for the gateway, the
# baseline server, and the load generator.
mkdir -p /etc/nitro_enclaves
cat > /etc/nitro_enclaves/allocator.yaml <<'YAML'
---
memory_mib: 3072
cpu_count: 2
YAML

# Allow the enclave to reach KMS through the parent. Without this entry
# vsock-proxy refuses the destination and every KMS call times out.
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -sX PUT \
  http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/placement/region)
cat > /etc/nitro_enclaves/vsock-proxy.yaml <<YAML
allowlist:
- {address: kms.${REGION}.amazonaws.com, port: 443}
YAML
echo "export AWS_REGION=${REGION}" >> /home/ec2-user/.bashrc

systemctl enable --now docker
systemctl enable --now nitro-enclaves-allocator.service
systemctl enable --now nitro-enclaves-vsock-proxy.service || \
    echo "vsock-proxy service absent; scripts/20_run_enclave.sh starts it manually"

nitro-cli describe-enclaves || true
echo "BOOTSTRAP COMPLETE"
