#!/bin/bash
# USMS data tier bootstrap. Runs ONCE at first boot. Idempotent: exits early if the marker exists.
MARKER=/var/log/usms-db-bootstrap.done
if [ -f "$MARKER" ]; then
  echo "usms-db bootstrap already done, exiting"
  exit 0
fi

set -x
exec > /var/log/usms-db-bootstrap.log 2>&1

dnf -y install postgresql15-server

# Instance ID via IMDSv2; fall back to the env var some emulators set.
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_ID=${INSTANCE_ID:-${AWS_EC2_INSTANCE_ID:-unknown}}

postgresql-setup --initdb
systemctl enable --now postgresql
sudo -u postgres createdb usms

printf '%s %s\n' "$INSTANCE_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
echo "usms-db bootstrap complete"
