#!/usr/bin/env bash
# Provision the multica agent runtime EC2 and register its kiro runtime.
#
# Validated 2026-08-06 against the stage-4 deployment:
#   - EC2: AL2023 arm64 (t4g.medium), public ALB subnet, SSH from operator IP
#   - kiro-cli installed via cli.kiro.dev installer
#   - multica CLI copied from the workspace host (must match server version)
#   - daemon runs as a systemd service and registers a `kiro` runtime
#
# Prereqs: terraform apply of deploy/aws/terraform, a multica PAT for the
# owning user (POST /api/tokens), and the multica binary matching the server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"
REGION="${AWS_REGION:-cn-northwest-1}"
OPERATOR_IP="${OPERATOR_IP:-69.234.227.150}"
ALB_DNS="${ALB_DNS:-k8s-multica-multica-4009a1c0af-2053026646.cn-northwest-1.elb.amazonaws.com.cn}"
WORKSPACE_ID="${WORKSPACE_ID:-59fb09ee-3f0a-407e-9d7d-176224ef2ef7}" # agentic-engineering
MULTICA_BIN="${MULTICA_BIN:-/usr/local/bin/multica}"
INSTANCE_ID=""

echo "==> [1/5] Terraform: create runtime EC2 + SG + keypair"
terraform -chdir="${TF_DIR}" apply -auto-approve \
  -target=aws_key_pair.runtime \
  -target=aws_security_group.runtime \
  -target=aws_instance.runtime
INSTANCE_ID="$(terraform -chdir="${TF_DIR}" output -raw runtime_instance_id)"
PUBLIC_IP="$(terraform -chdir="${TF_DIR}" output -raw runtime_public_ip)"
echo "    instance=${INSTANCE_ID} ip=${PUBLIC_IP}"

echo "==> [2/5] Wait for SSH"
for i in $(seq 1 20); do
  if ssh -i "${TF_DIR}/../../.keys/runtime-kiro.pem" -o StrictHostKeyChecking=no -o ConnectTimeout=8 ec2-user@"${PUBLIC_IP}" true 2>/dev/null; then
    break
  fi
  sleep 15
done

echo "==> [3/5] Copy multica CLI (server-matched version)"
scp -i "${TF_DIR}/../../.keys/runtime-kiro.pem" -o StrictHostKeyChecking=no \
  "${MULTICA_BIN}" ec2-user@"${PUBLIC_IP}":/tmp/multica
ssh -i "${TF_DIR}/../../.keys/runtime-kiro.pem" ec2-user@"${PUBLIC_IP}" \
  'sudo install -m 0755 /tmp/multica /usr/local/bin/multica'

echo "==> [4/5] Configure + authenticate + watch workspace"
ssh -i "${TF_DIR}/../../.keys/runtime-kiro.pem" ec2-user@"${PUBLIC_IP}" \
  "multica config set server_url http://${ALB_DNS} && \
   multica config set app_url http://${ALB_DNS} && \
   multica login --token=\"${MULTICA_PAT}\" && \
   multica workspace switch ${WORKSPACE_ID}"

echo "==> [5/5] Install systemd service and start daemon"
ssh -i "${TF_DIR}/../../.keys/runtime-kiro.pem" ec2-user@"${PUBLIC_IP}" \
  'sudo tee /etc/systemd/system/multica-daemon.service > /dev/null <<EOF
[Unit]
Description=Multica agent daemon (kiro runtime)
After=network-online.target
Wants=network-online.target

[Service]
User=ec2-user
Group=ec2-user
ExecStart=/usr/local/bin/multica daemon start --foreground
Restart=always
RestartSec=10
Environment=HOME=/home/ec2-user
Environment=PATH=/home/ec2-user/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now multica-daemon'

echo "==> Done. Verify: multica daemon status (on host) or GET /api/runtimes?workspace_id=${WORKSPACE_ID}"
