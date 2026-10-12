#!/usr/bin/env bash
# Export the enrolment service's complete scaling configuration and history as ONE JSON
# document: outputs/lab-06-scaling-history.json.
#   scalable target (bounds, suspension), every scaling policy, every scheduled action,
#   every alarm involved (with state), every scaling activity including not-scaled ones.
# Every identifier is discovered: the resource ID comes from the service ARN, policies and
# actions from describe- calls on that resource ID, alarms from the policies plus the
# alarms whose actions name a policy. Nothing is hard-coded but the Lab 04 cluster and
# service names, which configs/lab-04.env supplies.
#
# set -uo pipefail without -e: a section whose API call fails (on this Floci build, every
# Application Auto Scaling call) is recorded inside the document as {"error": "..."} so
# the export still describes everything that does exist. Read-only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
OUT="$REPO_ROOT/outputs/lab-06-scaling-history.json"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# call <file> <aws args...>: write the JSON answer, or {"error": "<message>"} on failure.
call() {
  local f="$TMP/$1"; shift
  if ! aws "$@" --output json >"$f" 2>"$f.err"; then
    python3 -c 'import json,sys;print(json.dumps({"error":open(sys.argv[1]).read().strip()}))' "$f.err" >"$f"
  fi
}

SVC_ARN=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
            --query 'services[0].serviceArn' --output text 2>/dev/null)
case "$SVC_ARN" in arn:*) ;; *) echo "cannot read the service ARN - is Floci running?" >&2; exit 1;; esac
RID="${SVC_ARN##*:}"     # service/<cluster>/<service>: the ARN's resource part, three segments

call target     application-autoscaling describe-scalable-targets  --service-namespace ecs --resource-ids "$RID"
call policies   application-autoscaling describe-scaling-policies  --service-namespace ecs --resource-id "$RID"
call scheduled  application-autoscaling describe-scheduled-actions --service-namespace ecs --resource-id "$RID"
call activities application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id "$RID" \
                --include-not-scaled-activities
call service    ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
                --query 'services[0].{desiredCount:desiredCount,runningCount:runningCount,pendingCount:pendingCount,taskDefinition:taskDefinition}'

# Alarms involved: the ones each policy lists (managed and custom), plus any alarm whose
# actions name a scaling policy on this resource. On a build without policies, the custom
# alarm is found through the namespace of the metric it watches instead.
POLICY_ALARMS=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(sorted({a["AlarmName"] for p in d.get("ScalingPolicies",[]) for a in p.get("Alarms",[])})))' "$TMP/policies")
call allalarms  cloudwatch describe-alarms
python3 - "$TMP/allalarms" "$RID" "$POLICY_ALARMS" > "$TMP/alarms" << 'PY'
import json, sys
d = json.load(open(sys.argv[1])); rid = sys.argv[2]; named = set(sys.argv[3].split())
if "error" in d:
    print(json.dumps(d)); sys.exit()
keep = [a for a in d.get("MetricAlarms", [])
        if a["AlarmName"] in named
        or any(rid in act for act in a.get("AlarmActions", []))
        or a.get("Namespace") == "USMS/Enrolment"]
print(json.dumps([{k: a.get(k) for k in ("AlarmName","Namespace","MetricName","Dimensions","Statistic",
       "Period","EvaluationPeriods","ComparisonOperator","Threshold","TreatMissingData",
       "AlarmActions","StateValue","StateReason","StateUpdatedTimestamp")} for a in keep], default=str))
PY

python3 - "$TMP" "$RID" "$SVC_ARN" "$OUT" << 'PY'
import json, sys, datetime, os
tmp, rid, arn, out = sys.argv[1:5]
load = lambda n: json.load(open(os.path.join(tmp, n)))
def section(n, key):
    d = load(n)
    return d if isinstance(d, dict) and "error" in d else d.get(key, [])
doc = {
  "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "resourceId": rid,
  "serviceArn": arn,
  "serviceNamespace": "ecs",
  "scalableDimension": "ecs:service:DesiredCount",
  "service": load("service"),
  "scalableTarget": section("target", "ScalableTargets"),
  "scalingPolicies": section("policies", "ScalingPolicies"),
  "scheduledActions": section("scheduled", "ScheduledActions"),
  "alarms": load("alarms"),
  "scalingActivities": section("activities", "ScalingActivities"),
}
os.makedirs(os.path.dirname(out), exist_ok=True)
json.dump(doc, open(out, "w"), indent=2, default=str)
PY

python3 -m json.tool "$OUT" >/dev/null || { echo "invalid JSON written to $OUT" >&2; exit 1; }
echo "wrote ${OUT#$REPO_ROOT/} ($(wc -c <"$OUT") bytes, valid JSON)"
