# Lab 05 - Independent Lab Exercises

Environment: Floci v1.5.34, AWS CLI v2.31.35, load balancer `usms-enrolment-alb`, support path A (the listener forwards real requests, but only inside Floci's Docker network; see the README).

Labels used throughout: **Observed** (seen in command output), **Conceptual** (reasoned about real AWS, not run), **Floci limitation** (this emulator behaves differently from real AWS). Full command output for each exercise is in [`evidence/`](evidence/).

---

## Exercise 1 - Basic: a second path through the same load balancer

Created `usms-results-tg` (ip, HTTP:80, in `usms-vpc`, health check `/`, matcher `200-399`, deregistration delay 15 s) and a rule at priority 20 on the existing listener, matching `/results` and `/results/*`, forwarding to it. Both objects are tagged `Project=USMS`, `Tier=app`, `Lab=05`, `Service=results`. Every ARN was captured with `$(...)` and `--query`, the condition and action are JSON documents in `templates/` (`lab-05-ex1-results-conditions.json`, quoted heredoc; `lab-05-ex1-results-actions.json`, unquoted because it carries the target group ARN, zero literal `$`), and neither object was added to `configs/lab-05.env`.

```bash
RESULTS_TG_ARN=$(aws elbv2 create-target-group --name usms-results-tg --protocol HTTP --port 80 \
  --vpc-id "$USMS_VPC_ID" --target-type ip --health-check-path / --matcher HttpCode=200-399 \
  --tags Key=Name,Value=usms-results-tg Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 modify-target-group-attributes --target-group-arn "$RESULTS_TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=15
RESULTS_RULE_ARN=$(aws elbv2 create-rule --listener-arn "$USMS_ALB_LISTENER_ARN" --priority 20 \
  --conditions file://templates/lab-05-ex1-results-conditions.json \
  --actions file://templates/lab-05-ex1-results-actions.json \
  --tags Key=Name,Value=usms-results-rule Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results \
  --query 'Rules[0].RuleArn' --output text)
```

Observed, rules in evaluation order ([evidence/lab-05-ex1.txt](evidence/lab-05-ex1.txt)):

```
10       /alb-health,/alb-health/*  fixed-response  200
20       /results,/results/*        forward         targetgroup/usms-results-tg/df2bdac9c7884180
default  -                          forward         targetgroup/usms-enrolment-tg/2414901868f64c56
```

`Priority` is a string and the default's value is the word `default`, so I sorted with `jq`, mapping `default` to a very large number and converting the rest with `tonumber`. A plain string sort would put `"10"` before `"9"`. `usms-results-tg` has no targets (`[]`) and is attached to one load balancer.

**A request to `/results` with no targets** gets a **503 Service Temporarily Unavailable from the load balancer itself**: the listener matched the rule but there is no healthy target to forward to. That is the "listener worked, no healthy targets" case in Section 10's curl entry. Observed on Floci through the listener: `/results` and `/results/x` returned 503 with no `Server: nginx` header (the load balancer answered), while `/resultsx` fell through to the default action and got nginx's 404.

---

## Exercise 2 - Intermediate: repair the verification script you broke

**The property the old check asserted:** the enrolment tasks accept tcp/80 only from a named security group (the one tier allowed to call them), never from an address range. `usms-app-sg` was just the value of that property while the web tier was the caller.

**Why my script did not fail after Step 13.** The lab expects `verify-lab-04.sh` to flip from 49/0 to 48/1. Mine stayed at 38/1, with no difference at all. In Lab 04 I had replaced the API read-back (Floci returns no `UserIdGroupPairs`) with a check that reads the Lab 04 rule *file*, and that file still names `usms-app-sg` after the cutover. So the check was testing my repository, not the environment, and was blind to the change it existed to detect. That is a worse failure than the one the exercise describes.

**What changed in `scripts/utilities/verify-lab-04.sh`** (no check deleted):

| Before | After |
|---|---|
| `enrolment rule file names usms-app-sg as its only source` | `usms-enrolment-sg is sourced from a group, and that group is usms-alb-sg`: reads the rule document now in force (`policies/usms-enrolment-sg-ingress-alb.json`) and compares it with `USMS_ALB_SG` from `configs/lab-05.env` |
| (none) | `usms-app-sg is no longer a source of usms-enrolment-sg`: exactly **one** inbound permission, and `usms-app-sg` not among the sources the API returns. After Step 9 there were two permissions, so this fails if both rules exist |
| `has NO CIDR-sourced ingress rule` | unchanged |
| `[floci] enrolment source group readable via the API` (expected `usms-app-sg`) | same check, now expecting `usms-alb-sg` |

`configs/lab-05.env` is sourced with `2>/dev/null || true` and `USMS_ALB_SG` defaults to `none` through `: "${USMS_ALB_SG:=none}"`, so under `set -u` a student without Lab 05 gets a failed check with a readable name rather than an unbound-variable abort. `${BASH_SOURCE[0]}` resolution is unchanged.

Observed ([evidence/lab-05-ex2-verify.txt](evidence/lab-05-ex2-verify.txt)):

| Run | Result |
|---|---|
| `verify-lab-04.sh` from the repository | **PASS=39 FAIL=1**, the `[floci]` read-back |
| `verify-lab-04.sh` from `~` | PASS=39 FAIL=1 |
| `verify-lab-04.sh` with `configs/lab-05.env` moved away | PASS=38 FAIL=2: the `usms-alb-sg` check fails readably, no abort |
| `verify-lab-05.sh` | PASS=52 FAIL=3, all `[floci]` |

I did not reach FAIL=0. The remaining failures are the labelled `[floci]` checks, each paired with a stand-in that passes; deleting them to get a green run would hide the Floci limitations instead of recording them.

The new count is stated in a comment at the top of the script. **An undocumented count is worse than none** because a reader who sees `FAIL=1` cannot tell whether it is the known failure or a new one that replaced it; a stated count, with the reason for each expected failure, makes any deviation visible.

**When updating a verification script is right, and when it hides a regression:** updating it is right when the architecture deliberately changed and the check is rewritten to assert the same property against the new design, in the same commit as the change, with the reason in the message. It hides a regression when the expected value is changed just to make a failing run pass, without a design decision behind it, because the script then agrees with whatever the environment happens to be.

I did not test the "both rules present" case live: Floci cannot revoke a single group-sourced rule (README, Step 13), so re-adding the Lab 04 rule could not be cleanly undone. The Step 9 state, with two inbound permissions, is the case that check would fail on.

---
