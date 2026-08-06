#!/bin/bash
exec > /var/log/user-data.log 2>&1
set -x

# Base tooling (curl is preinstalled as curl-minimal on AL2023)
yum install -y git jq unzip nodejs npm aws-cli

# Kiro CLI (ACP coding agent) — primary installer, npm fallback.
# Run with HOME exported: the installer requires it in cloud-init's shell.
export HOME=/root
curl -fsSL https://cli.kiro.dev/install | bash || true
if ! command -v kiro-cli >/dev/null 2>&1; then
  npm install -g @anthropic-ai/kiro-cli || true
fi

# multica CLI is copied to the host by deploy/aws/scripts/setup-runtime-ec2.sh
# (binary must match the deployed server version, e.g. 0.4.17).

# Daemon service (created by setup script; enable once multica is configured).
systemctl daemon-reload || true
