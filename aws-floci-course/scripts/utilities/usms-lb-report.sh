#!/usr/bin/env bash
# Print the decision table of every Application Load Balancer whose name starts with usms-:
# load balancer -> listeners -> rules in evaluation order -> target group health.
# Also writes outputs/lab-05-lb-report.json. Read-only. No arguments.
#
# set -uo pipefail, deliberately without -e: this is a report. One listener or target group
# that cannot be described must not stop the rest of the report; each call that can fail
# is checked and printed as an "ERROR" row instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
OUT="$REPO_ROOT/outputs/lab-05-lb-report.json"

# tg_summary <target group ARN> -> "usms-enrolment-tg (2 targets, 2 healthy)"
tg_summary() {
  local name th
  name="${1#*:targetgroup/}"; name="${name%%/*}"
  if ! th=$(aws elbv2 describe-target-health --target-group-arn "$1" --output json 2>/dev/null); then
    echo "$name (ERROR reading target health)"; return
  fi
  jq -r --arg n "$name" '.TargetHealthDescriptions as $t
    | "\($n) (\($t|length) targets, \([$t[]|select(.TargetHealth.State=="healthy")]|length) healthy)"' <<<"$th"
}

# action_summary <one action as JSON> -> one cell. Non-forward actions describe themselves.
action_summary() {
  local type; type=$(jq -r '.Type' <<<"$1")
  case "$type" in
    forward)
      # A forward action names one target group directly, or several in ForwardConfig (weighted).
      local arns; arns=$(jq -r '[.TargetGroupArn // empty, (.ForwardConfig.TargetGroups[]?.TargetGroupArn)] | unique | .[]' <<<"$1")
      local out="" a
      for a in $arns; do out="${out:+$out + }$(tg_summary "$a")"; done
      echo "${out:-forward (no target group)}" ;;
    fixed-response) jq -r '"fixed-response \(.FixedResponseConfig.StatusCode)"' <<<"$1" ;;
    redirect)       jq -r '"redirect \(.RedirectConfig.StatusCode) to \(.RedirectConfig.Protocol // "#{protocol}")://\(.RedirectConfig.Host // "#{host}")\(.RedirectConfig.Path // "/#{path}")"' <<<"$1" ;;
    *)              echo "$type" ;;
  esac
}

# condition_summary <rule as JSON> -> "path-pattern  /a,/b" or "-" for the default rule.
# Values can sit in the old flat Values list or in the typed *Config block (Floci uses only
# the typed block), so both are read.
condition_summary() {
  jq -r 'if (.Conditions|length)==0 then "-"
         else [.Conditions[] | "\(.Field)  \(((.Values // []) + (.PathPatternConfig.Values // []) + (.HostHeaderConfig.Values // [])) | unique | join(","))"] | join(" AND ") end' <<<"$1"
}

LBS=$(aws elbv2 describe-load-balancers --output json 2>/dev/null \
        | jq -c '[.LoadBalancers[] | select(.LoadBalancerName|startswith("usms-")) | select(.Type=="application")]') \
  || { echo "ERROR: describe-load-balancers failed - is Floci running?"; exit 1; }

REPORT='[]'
if [ "$(jq length <<<"$LBS")" -eq 0 ]; then
  echo "(no Application Load Balancer named usms-*)"
fi

while IFS= read -r lb; do
  [ -z "$lb" ] && continue
  lb_arn=$(jq -r .LoadBalancerArn <<<"$lb")
  jq -r '"\(.LoadBalancerName)   \(.Scheme)  \(.Type)  \(.State.Code)  AZs=\(.AvailabilityZones|length)  SGs=\(.SecurityGroups|length)"' <<<"$lb"
  lb_json=$(jq -c '{name:.LoadBalancerName, scheme:.Scheme, type:.Type, state:.State.Code, azs:(.AvailabilityZones|length), sgs:(.SecurityGroups|length), listeners:[]}' <<<"$lb")

  if ! listeners=$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" --output json 2>/dev/null); then
    echo "  ERROR reading listeners"; listeners='{"Listeners":[]}'
  fi
  if [ "$(jq '.Listeners|length' <<<"$listeners")" -eq 0 ]; then
    echo "  (no listeners - this load balancer answers nothing)"
  fi

  while IFS= read -r l; do
    [ -z "$l" ] && continue
    l_arn=$(jq -r .ListenerArn <<<"$l")
    jq -r '"  \(.Protocol):\(.Port)"' <<<"$l"
    if ! rules=$(aws elbv2 describe-rules --listener-arn "$l_arn" --output json 2>/dev/null); then
      echo "    ERROR reading rules"; continue
    fi
    # Evaluation order. Priority is a STRING ("10", "20") and the default rule's is the word
    # "default": a plain sort would put "10" before "9" and could put "default" anywhere.
    # Numbers are compared as numbers and "default" is mapped past the largest legal priority
    # (50000), so it is always printed last - which is also when the load balancer runs it.
    ordered=$(jq -c '.Rules | sort_by(if .Priority=="default" then 50001 else (.Priority|tonumber) end) | .[]' <<<"$rules")
    l_rules='[]'
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      prio=$(jq -r .Priority <<<"$r")
      cond=$(condition_summary "$r")
      act=$(action_summary "$(jq -c '.Actions[0]' <<<"$r")")
      printf '    prio  %-7s  %-42s -> %s\n' "$prio" "$cond" "$act"
      l_rules=$(jq -c --arg p "$prio" --arg c "$cond" --arg a "$act" '. + [{priority:$p, condition:$c, action:$a}]' <<<"$l_rules")
    done <<<"$ordered"
    lb_json=$(jq -c --arg l "$(jq -r '"\(.Protocol):\(.Port)"' <<<"$l")" --argjson r "$l_rules" '.listeners += [{listener:$l, rules:$r}]' <<<"$lb_json")
  done < <(jq -c '.Listeners | sort_by(.Port) | .[]' <<<"$listeners")

  REPORT=$(jq -c --argjson lb "$lb_json" '. + [$lb]' <<<"$REPORT")
  echo
done < <(jq -c '.[]' <<<"$LBS")

mkdir -p "$(dirname "$OUT")"
jq . <<<"$REPORT" > "$OUT"
echo "JSON written to ${OUT#$REPO_ROOT/}"
