#!/usr/bin/env bash
# Print the ResourceLabel that Application Auto Scaling's ALBRequestCountPerTarget metric needs:
#   <load-balancer ARN suffix>/<target-group ARN suffix>
#   app/usms-enrolment-alb/<id>/targetgroup/usms-enrolment-tg/<id>
# Both ARNs are looked up from the API by name, never read from configs/ or typed.
# Usage: usms-resource-label.sh [load-balancer-name] [target-group-name]
# Read-only. Exit 1, printing nothing on stdout, if the result is not plausible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"   # profile and endpoint only; no ARNs come from configs/

LB_NAME="${1:-usms-enrolment-alb}"
TG_NAME="${2:-usms-enrolment-tg}"

die() { echo "usms-resource-label: $*" >&2; exit 1; }

LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" \
           --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null) \
  || die "no load balancer named $LB_NAME"
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
           --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) \
  || die "no target group named $TG_NAME"

# The two suffixes are cut differently, because the label keeps one resource-type word and
# drops the other:
#   load balancer  arn:...:loadbalancer/app/usms-enrolment-alb/<id>
#                  -> everything AFTER ":loadbalancer/"   (the word "loadbalancer" is dropped)
#   target group   arn:...:targetgroup/usms-enrolment-tg/<id>
#                  -> everything after the LAST ":"       (the word "targetgroup" is kept)
# Shell parameter expansion does both: ${var#pattern} removes the shortest matching prefix,
# ${var##pattern} the longest.
LB_SUFFIX="${LB_ARN#*:loadbalancer/}"
TG_SUFFIX="${TG_ARN##*:}"
LABEL="$LB_SUFFIX/$TG_SUFFIX"

# Plausibility: exactly six segments - app, LB name, LB id, targetgroup, TG name, TG id -
# the first is the literal "app", and both names appear where they should.
IFS=/ read -r -a SEG <<<"$LABEL"
[ "${#SEG[@]}" -eq 6 ]          || die "expected 6 segments, got ${#SEG[@]}: $LABEL"
[ "${SEG[0]}" = app ]           || die "first segment is '${SEG[0]}', not 'app' (not an Application Load Balancer?): $LABEL"
[ "${SEG[1]}" = "$LB_NAME" ]    || die "segment 2 is not $LB_NAME: $LABEL"
[ "${SEG[3]}" = targetgroup ]   || die "segment 4 is not 'targetgroup': $LABEL"
[ "${SEG[4]}" = "$TG_NAME" ]    || die "segment 5 is not $TG_NAME: $LABEL"
[ -n "${SEG[2]}" ] && [ -n "${SEG[5]}" ] || die "an ID segment is empty: $LABEL"

echo "$LABEL"
