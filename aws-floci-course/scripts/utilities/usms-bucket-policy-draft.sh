#!/usr/bin/env bash
# USMS bucket policy DRAFT (Lab 09 Exercise 5). Read-only: writes two files under outputs/
# and applies nothing. The S3 configuration lab applies the draft; Lab 10 only validates it.
#
#   outputs/lab-09-bucket-policy-draft.json   the resource policy for the transcripts bucket
#   outputs/lab-09-lab10-readiness.txt        what Lab 10 needs to know, one labelled line each
#
# The bucket is never typed: it is read out of USMSStudentDataReadWrite's Resource. The
# principals are every role whose identity policies already grant an s3: action on that
# bucket; each is allowed exactly the actions it already has. No access key is read or used.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-01.env"  2>/dev/null || true

INVENTORY="outputs/lab-09-identity-inventory.json"
[ -f "$INVENTORY" ] || { echo "no $INVENTORY - run Lab 09 Step 4 part 2 first" >&2; exit 2; }

# The bucket ARN, read from the Lab 01 policy's ListBucket statement (the bucket-level ARN).
RW_ARN="arn:aws:iam::${USMS_ACCOUNT_ID:-000000000000}:policy/USMSStudentDataReadWrite"
RW_VER=$(aws iam get-policy --policy-arn "$RW_ARN" --query 'Policy.DefaultVersionId' --output text)
BUCKET_ARN=$(aws iam get-policy-version --policy-arn "$RW_ARN" --version-id "$RW_VER" \
  --query 'PolicyVersion.Document.Statement[?Effect==`Allow`].Resource[]' --output json \
  | python3 -c "import json,sys;print(next(r for r in json.load(sys.stdin) if r.startswith('arn:aws:s3:::') and '/' not in r))")
# Parameter expansion, not a second API call or a hard-coded name: strip the fixed
# "arn:aws:s3:::" prefix so the bucket NAME is derived from the same document as the ARN.
BUCKET="${BUCKET_ARN#arn:aws:s3:::}"
[ -n "$BUCKET" ] && [ "$BUCKET" != "$BUCKET_ARN" ] || { echo "could not derive the bucket from $RW_ARN" >&2; exit 2; }

HEAD_RC=0; aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || HEAD_RC=$?

python3 - "$INVENTORY" "$BUCKET_ARN" "$BUCKET" "${USMS_ACCOUNT_ID:-000000000000}" "$HEAD_RC" << 'PY'
import json, sys
inv, bucket_arn, bucket, account, head_rc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
roles = json.load(open(inv))
objects = bucket_arn + "/*"

def as_list(x):
    return [] if x is None else (x if isinstance(x, list) else [x])

def names_bucket(res):
    return any(r in (bucket_arn, objects) or r.startswith(bucket_arn + "/") for r in res)

granted, policies = {}, {}
for r in roles:
    for p in r.get("attachedPolicies", []) + r.get("inlinePolicies", []):
        doc = p.get("document") or {}
        for st in as_list(doc.get("Statement")):
            res = as_list(st.get("Resource"))
            if not names_bucket(res):
                continue
            policies.setdefault(p["name"], set())
            if st.get("Effect") != "Allow":
                continue
            acts = [a for a in as_list(st.get("Action")) if a.lower().startswith("s3:")]
            if acts:
                granted.setdefault(r["arn"], set()).update(acts)
                policies[p["name"]].add(r["arn"])

principals = sorted(granted)
statements = []
for arn in principals:
    statements.append({
        "Sid": "AllowWhatThisRoleAlreadyHas" + arn.rsplit("/", 1)[-1].replace("-", "").title(),
        "Effect": "Allow",
        "Principal": {"AWS": arn},
        "Action": sorted(granted[arn]),
        "Resource": [bucket_arn, objects],
    })
statements.append({
    "Sid": "DenyAnyRequestNotOverTLS",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [bucket_arn, objects],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}},
})
statements.append({
    "Sid": "DenyEveryoneButTheseRolesAndTheAccountRoot",
    "Effect": "Deny",
    "NotPrincipal": {"AWS": principals + [f"arn:aws:iam::{account}:root"]},
    "Action": "s3:*",
    "Resource": [bucket_arn, objects],
})
draft = {"Version": "2012-10-17", "Id": "USMSTranscriptsBucketPolicyDraft", "Statement": statements}
json.dump(draft, open("outputs/lab-09-bucket-policy-draft.json", "w"), indent=2)

names = sorted(policies)
lines = [
    "# Lab 09 Exercise 5 - readiness for Lab 10, derived from policy documents and the identity inventory",
    f"bucket name (from USMSStudentDataReadWrite) : {bucket}",
    f"bucket exists today                         : {'yes' if head_rc == 0 else 'no - head-bucket exit ' + str(head_rc)}",
    f"policies naming the bucket ({len(names)})            : {' '.join(names)}",
]
for n in names:
    lines.append(f"  {n:<42} roles: {' '.join(sorted(policies[n])) or '(attached to no role)'}")
lines += [
    f"principals in the draft's Allow statements   : {len(principals)}",
    "what changes when Lab 10 runs create-bucket  : nothing in IAM changes, but every one of these "
    f"{len(principals)} roles goes from holding permissions on a bucket that does not exist to holding "
    "them on a real one, and the read-write holders can PUT and DELETE objects from that moment, until "
    "this draft (or a narrower identity policy) is applied.",
]
open("outputs/lab-09-lab10-readiness.txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
print(f"\ndraft: {len(statements)} statements -> outputs/lab-09-bucket-policy-draft.json")
PY
