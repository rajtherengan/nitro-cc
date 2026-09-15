#!/usr/bin/env bash
# Run once on a fresh Amazon Linux 2023 parent instance.
#
# Instance requirements, all easy to get wrong:
#   * Nitro-based type with enclave support: m5.xlarge, c5.xlarge, m6i.xlarge,
#     c6i.xlarge or larger. NOT t2/t3/t4g -- enclaves are unsupported there.
#   * At least 4 vCPUs. The allocator takes CPUs away from the parent, so on a
#     2-vCPU box the parent is left with nothing and your baseline number
#     becomes meaningless.
#   * Launched with --enclave-options Enabled=true. This CANNOT be changed
#     after launch; you will have to relaunch the instance.
#   * An instance profile granting kms:Decrypt on your key.
#
#   aws ec2 run-instances --instance-type m5.xlarge \
#       --enclave-options Enabled=true --image-id <al2023-ami> \
#       --iam-instance-profile Name=<profile> --key-name <key>
set -euo pipefail

sudo dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel docker git
sudo usermod -aG ne "$USER"
sudo usermod -aG docker "$USER"

# Carve fixed resources out of the parent. These are reserved at boot and are
# NOT shared -- the parent genuinely loses them for as long as the allocator
# service is running.
sudo tee /etc/nitro_enclaves/allocator.yaml > /dev/null <<'YAML'
---
memory_mib: 3072
cpu_count: 2
YAML

sudo systemctl enable --now docker
sudo systemctl enable --now nitro-enclaves-allocator.service

echo
echo "Log out and back in for the group changes, then verify:"
echo "  nitro-cli describe-enclaves     # -> []"
echo "  lscpu | grep -i 'on-line'       # parent should have lost 2 vCPUs"
