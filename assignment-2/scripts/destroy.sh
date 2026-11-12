#!/usr/bin/env bash
# Tear the platform down.
#   scripts/destroy.sh         Floci (everything, including data)
#   scripts/destroy.sh aws     AWS: deletion protection on the database and the user pool
#                              must be switched off first (see README), on purpose.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-floci}"
VARS=()
if [ "$TARGET" = floci ]; then
  export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
  VARS=(-var-file=floci.tfvars)
fi
cd "$ROOT/infra"
terraform init -input=false -no-color > /dev/null
terraform destroy -input=false -auto-approve -no-color "${VARS[@]}"

if [ "$TARGET" = floci ]; then
  # The course runs Floci with FLOCI_STORAGE_PRUNE_VOLUMES_ON_DELETE=false, so a deleted
  # RDS instance leaves its PostgreSQL data directory behind. A later deploy would reuse
  # it, and PostgreSQL would keep the old password. Remove it (the files belong to the
  # container's postgres user, so a throwaway container does the deleting).
  host_dir="$(docker inspect floci --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^FLOCI_STORAGE_HOST_PERSISTENT_PATH=//p')"
  ns="$(docker inspect floci --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^FLOCI_DOCKER_RESOURCE_NAMESPACE=//p')"
  if [ -n "$host_dir" ] && [ -d "$host_dir/$ns/rds/exam-db" ]; then
    docker run --rm -v "$host_dir/$ns/rds:/rds" postgres:16-alpine rm -rf /rds/exam-db
    echo "removed Floci's leftover data directory for exam-db"
  fi
fi
