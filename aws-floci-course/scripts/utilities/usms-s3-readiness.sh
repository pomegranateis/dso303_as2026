#!/usr/bin/env bash
# USMS S3 readiness (Lab 10 Exercise 5). Read-only: applies nothing.
#
# 1. Validates outputs/lab-09-bucket-policy-draft.json against what now exists:
#    every bucket ARN must be the real bucket, every principal an existing role
#    (or the account root). Mismatches are reported, never fixed silently.
# 2. Confirms the draft is still UNAPPLIED (get-bucket-policy must fail).
# 3. Writes outputs/lab-10-s3-readiness.txt: bucket, objects, notification, functions
#    and versions, CloudFront support, and the validation result.
# Re-run it at any time; it regenerates the file from live calls.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-10.env" 2>/dev/null || true

BUCKET="${USMS_BUCKET_ARN#arn:aws:s3:::}"
BUCKET="${BUCKET:-usms-student-data}"
DRAFT="${USMS_DRAFT:-outputs/lab-09-bucket-policy-draft.json}"   # overridable for a negative test
OUT="${USMS_READINESS_OUT:-outputs/lab-10-s3-readiness.txt}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The draft: Lab 09 Exercise 5 wrote it. If it is missing, write the minimal equivalent
# the exercise describes (GetObject for every role carrying USMSStudentDataReadWrite).
if [ ! -f "$DRAFT" ]; then
  echo "no $DRAFT - generating the minimal equivalent" >&2
  RW=arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite
  for r in $(aws iam list-roles --query 'Roles[].RoleName' --output text); do
    aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text \
      | grep -qw "$RW" && aws iam get-role --role-name "$r" --query Role.Arn --output text
  done > "$TMP/roles.txt"
  python3 - "$TMP/roles.txt" "$DRAFT" << 'PY'
import json, sys
roles = [l.strip() for l in open(sys.argv[1]) if l.strip()]
json.dump({"Version": "2012-10-17", "Statement": [{"Sid": "RolesCarryingReadWrite", "Effect": "Allow",
           "Principal": {"AWS": roles}, "Action": "s3:GetObject",
           "Resource": "arn:aws:s3:::usms-student-data/*"}]}, open(sys.argv[2], "w"), indent=2)
PY
fi

# Every ARN in the draft, and whether it resolves.
python3 - "$DRAFT" > "$TMP/arns.txt" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
seen = set()
for s in d["Statement"]:
    p = s.get("Principal", s.get("NotPrincipal"))
    if isinstance(p, dict):
        for a in (p["AWS"] if isinstance(p["AWS"], list) else [p["AWS"]]):
            seen.add(("principal", a))
    for r in (s["Resource"] if isinstance(s["Resource"], list) else [s["Resource"]]):
        seen.add(("resource", r))
for kind, a in sorted(seen):
    print(kind, a)
PY
MISMATCH=0
while read -r kind arn; do
  case "$kind:$arn" in
    principal:*:root)  ok=yes ;;                                   # the account root always exists
    principal:*:role/*) aws iam get-role --role-name "${arn##*/}" >/dev/null 2>&1 && ok=yes || ok=no ;;
    resource:*)        b="${arn#arn:aws:s3:::}"; b="${b%%/*}"
                       [ "$b" = "$BUCKET" ] && aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 && ok=yes || ok=no ;;
    *)                 ok=no ;;
  esac
  [ "$ok" = yes ] || MISMATCH=$((MISMATCH+1))
  printf '  %-4s %-9s %s\n' "$ok" "$kind" "$arn"
done < "$TMP/arns.txt" > "$TMP/validation.txt"

if aws s3api get-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1; then APPLIED="APPLIED - the draft must stay unapplied until the S3 lab"
else APPLIED="no bucket policy - correct, the S3 configuration lab applies it"; fi

NOTE=$(aws s3api get-bucket-notification-configuration --bucket "$BUCKET" \
  --query 'LambdaFunctionConfigurations[0].[Id,LambdaFunctionArn,join(`,`, Filter.Key.FilterRules[].join(`=`, [Name,Value]))]' --output text)
FUNCS=$(for f in usms-edge-viewer-request usms-edge-origin-response usms-transcript-notifier; do
  printf '%s(versions %s) ' "$f" "$(aws lambda list-versions-by-function --function-name "$f" --query "join(',', Versions[?Version!='\$LATEST'].Version)" --output text)"; done)

{
  echo "# Lab 10 Exercise 5 - S3 readiness, generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/utilities/usms-s3-readiness.sh"
  echo "bucket name            : $BUCKET"
  echo "bucket ARN             : arn:aws:s3:::$BUCKET"
  echo "objects in transcripts/: $(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix transcripts/ --query 'length(Contents)' --output text)"
  echo "notification           : $NOTE"
  echo "functions              : $FUNCS"
  echo "cloudfront supported   : ${USMS_CLOUDFRONT_SUPPORTED:-unknown} (distribution ${USMS_CLOUDFRONT_DIST_ID:-not-created}; associations stored as 0 - see the Lab 10 report)"
  echo "bucket policy          : $APPLIED"
  echo "draft validation       : $DRAFT - $( [ "$MISMATCH" -eq 0 ] && echo 'every ARN resolves' || echo "$MISMATCH MISMATCH(ES) - see below")"
  cat "$TMP/validation.txt"
} > "$OUT"
cat "$OUT"
