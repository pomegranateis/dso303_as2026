#!/usr/bin/env bash
# ECS configuration drift report: one line per service in the Lab 04 cluster.
#
#   usms-enrolment-svc   desired=2  running=2  taskdef=usms-enrolment:2  roles=SEPARATE  publicip=OK
#
# Verdicts are COMPUTED from the live configuration, never taken from a name or a tag:
#   roles     SAME      executionRoleArn equals taskRoleArn
#             SEPARATE  both are set and they differ
#             N/A       one of them is not set, so there is nothing to compare
#   publicip  RISK      assignPublicIp is ENABLED
#             OK        assignPublicIp is DISABLED
#             N/A       the service has no awsvpc networkConfiguration (e.g. EC2 launch type)
#
# Also writes the same data as JSON to outputs/lab-04-ecs-inventory.json.
# Read-only. Runs correctly from any directory.
#
# set -u and pipefail are on. set -e is deliberately OFF: an inventory must report on
# every service, so one service that fails to describe must not abort the whole run.
# Each failure is handled explicitly below and printed as an ERROR line instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"

OUT_JSON="$REPO_ROOT/outputs/lab-04-ecs-inventory.json"
mkdir -p "$REPO_ROOT/outputs"

# No service names are hard-coded: list them from the cluster, then describe each one.
ARNS="$(aws ecs list-services --cluster "$USMS_ECS_CLUSTER" \
          --query 'serviceArns[]' --output text 2>/dev/null)"
if [ $? -ne 0 ]; then
  echo "ERROR: could not list services in cluster $USMS_ECS_CLUSTER" >&2
  exit 1
fi

JSON_LINES=""
COUNT=0

for arn in $ARNS; do
  COUNT=$((COUNT + 1))
  svc_json="$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
                --services "$arn" --output json 2>/dev/null)"
  if [ $? -ne 0 ] || [ -z "$svc_json" ]; then
    printf '%-20s ERROR: describe-services failed\n' "${arn##*/}"
    continue
  fi

  name="$(jq -r '.services[0].serviceName // "N/A"' <<<"$svc_json")"
  desired="$(jq -r '.services[0].desiredCount // "N/A"' <<<"$svc_json")"
  running="$(jq -r '.services[0].runningCount // "N/A"' <<<"$svc_json")"
  taskdef_full="$(jq -r '.services[0].taskDefinition // empty' <<<"$svc_json")"
  assign="$(jq -r '.services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp // empty' <<<"$svc_json")"

  # taskdef: show family:revision whether the API returned an ARN or a bare name
  taskdef="${taskdef_full##*/}"
  [ -z "$taskdef" ] && taskdef="N/A"

  # roles: need the task definition document
  roles="N/A"
  if [ -n "$taskdef_full" ]; then
    td_json="$(aws ecs describe-task-definition --task-definition "$taskdef_full" \
                 --output json 2>/dev/null)"
    if [ $? -eq 0 ] && [ -n "$td_json" ]; then
      exec_role="$(jq -r '.taskDefinition.executionRoleArn // empty' <<<"$td_json")"
      task_role="$(jq -r '.taskDefinition.taskRoleArn // empty' <<<"$td_json")"
      if [ -n "$exec_role" ] && [ -n "$task_role" ]; then
        if [ "$exec_role" = "$task_role" ]; then roles="SAME"; else roles="SEPARATE"; fi
      fi
    fi
  fi

  # publicip: only meaningful when the service has an awsvpc configuration
  case "$assign" in
    ENABLED)  publicip="RISK" ;;
    DISABLED) publicip="OK" ;;
    *)        publicip="N/A" ;;
  esac

  printf '%-20s desired=%-2s running=%-2s taskdef=%-20s roles=%-9s publicip=%s\n' \
    "$name" "$desired" "$running" "$taskdef" "$roles" "$publicip"

  JSON_LINES+="$(jq -nc \
    --arg name "$name" --arg desired "$desired" --arg running "$running" \
    --arg taskdef "$taskdef" --arg roles "$roles" --arg publicip "$publicip" \
    '{service:$name, desired:$desired, running:$running, taskdef:$taskdef, roles:$roles, publicip:$publicip}')"$'\n'
done

if [ "$COUNT" -eq 0 ]; then
  echo "(no services in cluster $USMS_ECS_CLUSTER)"
  echo '[]' > "$OUT_JSON"
else
  printf '%s' "$JSON_LINES" | jq -s . > "$OUT_JSON"
fi
echo "JSON written to ${OUT_JSON#$REPO_ROOT/}" >&2
