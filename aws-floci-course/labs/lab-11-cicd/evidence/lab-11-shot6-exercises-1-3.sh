#!/usr/bin/env bash
# Lab 11 screenshot 6 - Exercises 1-3 (live readback; local-runner results from the saved test output)
cd ~/dso303_as2026/aws-floci-course && source configs/course.env; export AWS_PAGER=""
D=$(mktemp -d)
echo "== Ex1: a second project on the same role; its artifact names its own service =="
aws codebuild batch-get-projects --names usms-enrolment-build usms-results-build \
  --query 'projects[].[name,serviceRole,source.type,source.location]' --output text | sed 's|arn:aws:iam::000000000000:role/||; s/^/  /'
aws s3api get-object --bucket usms-pipeline-artifacts --key usms-results-build-2.zip $D/r.zip >/dev/null
unzip -p $D/r.zip build-metadata.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  usms-results-build-2.zip -> service=%s release=%s buildId=%s" % (d["service"], d["release"], d["buildId"]))'
sed -n 's/^ *logs:PutLogEvents /  logs /p' outputs/lab-11-ex1-template.txt
echo "== Ex2: finally - local runner + finally vs Floci =="
grep -E '^runner exit' outputs/lab-11-ex2-local.txt | sed 's/dist\/build-summary.txt: /summary: /; s/ finishedAt=.*//; s/^/  local: /'
aws codebuild batch-get-builds --ids usms-results-build:4 usms-results-build:5 \
  --query 'builds[].[id,buildStatus,phases[?phaseType==`POST_BUILD`]|[0].contexts[0].message]' --output text | sed 's/^/  floci probe: /'
aws s3api get-object --bucket usms-pipeline-artifacts --key usms-enrolment-build-23.zip $D/b.zip >/dev/null
echo "  floci build 23 (FAILED, broken test): artifact uploaded; build-summary.txt entries in it: $(unzip -Z1 $D/b.zip | grep -c build-summary)"
echo "    files: $(unzip -Z1 $D/b.zip | tr '\n' ' ')"
echo "== Ex3: JSON-parsing config check (local runner, five shapes of service.json) =="
python3 - << 'PY2'
import re
for line in open("outputs/lab-11-ex3-matrix.txt").read().splitlines()[1:6]:
    m = re.match(r"(.*?)\s+old-container-grep=(\S+)\s+old-port-grep=(\S+)\s+new-build=(\S+)\s*(.*)", line)
    name, oc, op, new, msg = m.groups()
    print("  %-26s old greps: container=%-4s port=%-4s | new check: build %s" % (name, oc, op, new))
    if msg: print("      " + msg)
PY2
echo "== Ex3: trust-codebuild.json as stored in IAM =="
aws iam get-role --role-name usms-codebuild-role --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json | python3 -c 'import json,sys; c=json.load(sys.stdin); [print("  %-13s %-18s %s" % (op, k, x)) for op in c for k, v in c[op].items() for x in (v if isinstance(v, list) else [v])]'
rm -rf $D
