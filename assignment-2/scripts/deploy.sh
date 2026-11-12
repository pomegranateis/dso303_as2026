#!/usr/bin/env bash
# Deploy the whole platform from code: package the functions, terraform apply
# (infrastructure + frontend), then create the database schema and seed data.
#
#   scripts/deploy.sh          deploy to Floci at http://localhost:4566 (floci.tfvars)
#   scripts/deploy.sh aws      deploy to the AWS account in your current credentials
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-floci}"

if [ "$TARGET" = floci ]; then
  export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
  export AWS_ENDPOINT_URL=http://localhost:4566
  curl -sf "$AWS_ENDPOINT_URL/_floci/health" > /dev/null || { echo "Floci is not answering on $AWS_ENDPOINT_URL" >&2; exit 1; }
  VARS=(-var-file=floci.tfvars)
else
  VARS=()
fi
export AWS_PAGER=""

echo "== 1/3 package the Lambda functions"
"$ROOT/scripts/build.sh"

echo "== 2/3 terraform apply ($TARGET)"
cd "$ROOT/infra"
terraform init -input=false -no-color > /dev/null
terraform apply -input=false -auto-approve -no-color "${VARS[@]}"

echo "== 3/3 database schema and seed data (direct invoke of the API function)"
FN="$(terraform output -raw exam_api_function)"
aws lambda wait function-active-v2 --function-name "$FN"
aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
  --cli-read-timeout 300 --payload '{"action":"migrate"}' "$ROOT/build/migrate.json" > /dev/null
cat "$ROOT/build/migrate.json"; echo

echo
echo "App:  $(terraform output -raw app_url)"
echo "API:  $(terraform output -raw api_base_url)"
echo "Users: $(terraform output -json demo_users)"
