#!/usr/bin/env bash
set -euo pipefail

IMDS_BASE="http://169.254.169.254/latest"

token="$(curl -fsS -X PUT "${IMDS_BASE}/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
if [ -z "${token}" ]; then
  exit 0
fi

key="$(curl -fsS -H "X-aws-ec2-metadata-token: ${token}" \
  "${IMDS_BASE}/meta-data/public-keys/0/openssh-key" || true)"
if [ -z "${key}" ]; then
  exit 0
fi

install -d -m 700 /home/ec2-user/.ssh

if ! grep -qxF "${key}" /home/ec2-user/.ssh/authorized_keys 2>/dev/null; then
  printf '%s\n' "${key}" >> /home/ec2-user/.ssh/authorized_keys
fi

chmod 600 /home/ec2-user/.ssh/authorized_keys
chown -R ec2-user:ec2-user /home/ec2-user/.ssh
