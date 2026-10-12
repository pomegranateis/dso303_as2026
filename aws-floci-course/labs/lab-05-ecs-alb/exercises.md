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

## Exercise 3 - Problem solving: a load balancer report tool

`scripts/utilities/usms-lb-report.sh` takes no arguments, walks every Application Load Balancer whose name starts with `usms-`, and prints its decision table. It also writes `outputs/lab-05-lb-report.json`.

Design decisions:

- **Four levels of calls**, done in bash with `jq`: `describe-load-balancers` (filtered with `startswith("usms-")` and `Type=="application"`), `describe-listeners`, `describe-rules`, `describe-target-health`. `jq` is already a course dependency, so I did not need to switch to python3.
- **Runs from any directory**: `REPO_ROOT` is resolved from `${BASH_SOURCE[0]}`, as in Section 8.
- **`set -uo pipefail`, no `-e`**: it is a report, so a listener or target group that cannot be described must not stop the rest. Each such call is checked and printed as an `ERROR` row.
- **Evaluation order**: `Priority` is a string and the default rule's is the word `default`. Numbers are compared as numbers (`tonumber`), and `default` is mapped to 50001, one past the largest legal priority, so it always prints last, which is also when the load balancer runs it.
- **Non-forward actions print their own summary**: `fixed-response <code>`, `redirect <code> to <url>`; a weighted forward lists each target group with its counts.
- **Conditions** are read from both the flat `Values` list and the typed `PathPatternConfig`/`HostHeaderConfig` blocks, because Floci fills only the typed block (README, Step 15).

Observed on the real load balancer, identical from the repository root, from `~` and from `labs/lab-05-ecs-alb/` ([evidence/lab-05-ex3-report.txt](evidence/lab-05-ex3-report.txt)):

```
usms-enrolment-alb   internet-facing  application  active  AZs=2  SGs=1
  HTTP:80
    prio  10       path-pattern  /alb-health,/alb-health/*    -> fixed-response 200
    prio  20       path-pattern  /results,/results/*          -> usms-results-tg (0 targets, 0 healthy)
    prio  default  -                                          -> usms-enrolment-tg (2 targets, 2 healthy)
```

**Edge cases tested before use** against a mock `aws` placed first on `PATH` ([evidence/lab-05-ex3-mock.txt](evidence/lab-05-ex3-mock.txt)): a load balancer with no listeners (prints "no listeners - this load balancer answers nothing"), a listener with only a default rule, an empty target group (`0 targets, 0 healthy`), priorities `"9"` and `"10"` (9 printed first; a string sort would reverse them), a default `redirect`, a weighted forward to two target groups, a `describe-rules` call that fails (prints `ERROR reading rules` and continues), and a non-`usms-` ALB and a network load balancer (both skipped). The run after Exercise 4's tidy-up is in the Exercise 4 section.

I tested "the `/alb-health` rule temporarily deleted" with the mock (a listener with only its default rule) rather than deleting the real rule, because `verify-lab-05.sh` asserts that rule and recreating it would give it a new ARN.

---

## Exercise 4 - Challenge: the exposure review

*Written for the university's information security officer and the finance team.*

### What changed

The enrolment API used to be reached only by the portal's web servers calling the tasks' private addresses directly; it is now reached through `usms-enrolment-alb`, a load balancer with public addresses in the two public subnets, which forwards HTTP on port 80 to the same private tasks. The tasks' security group used to admit tcp/80 from the web tier's group (`usms-app-sg`); it now admits tcp/80 only from the load balancer's group (`usms-alb-sg`), and the load balancer's group admits tcp/80 (and 443) from the whole internet.

### Should you be worried? Internal versus internet-facing

**The case for `--scheme internal`.** The portal (`usms-web-01`) is the only client of this API, and it lives inside the VPC. An internal load balancer would give the API the same stable name, health checks and draining, with no public exposure. Changes to Step 5:

- `--scheme internal` instead of `internet-facing`; the nodes could then sit in the private subnets.
- `usms-alb-sg` would admit tcp/80 from `usms-app-sg` instead of `0.0.0.0/0`, so the course would have no `0.0.0.0/0` ingress rule at all.
- The DNS name gains an `internal-` prefix and resolves only to private addresses, so it is useless from outside the VPC.

What does not change: the target group, the listener and its rules, the service's `loadBalancers` entry, the tasks' rule (`usms-alb-sg` only) and the private tasks. Scheme cannot be changed after creation, so this means creating a new load balancer and pointing the service at it.

**Recommendation: internal.** Nothing outside the VPC needs to call this API today, so the public exposure buys nothing and costs $7.30 a month in public addresses (below).

**The other side, in two sentences:** an internet-facing load balancer is what you need the day the enrolment API is called directly by a mobile app or a partner system, or when the portal moves out of this VPC. It also gives one place to put TLS, a web application firewall and rate limiting in front of the API, which an internal load balancer would still need if the portal itself were ever made public.

### The exposure delta

| Who can reach... | Before (Lab 04) | After (Lab 05) |
|---|---|---|
| **the load balancer** | there was none | anyone on the internet, tcp/80 (and tcp/443, where nothing listens yet) |
| **the tasks, through the load balancer** | not possible | anyone on the internet, but only via the listener: only port 80, only HTTP requests, only what the rules route to `usms-enrolment-tg` |
| **the tasks directly, by address** | `usms-web-01` and `usms-web-02` (both carry `usms-app-sg`) | only the load balancer's nodes (`usms-alb-sg`); the web tier no longer can |

What can reach the tasks now that could not before: **the internet**, indirectly through the listener. What could reach them before and now cannot: **the web servers, directly**. The tasks still have no public address in either case.

### Monthly cost (us-east-1)

Sources, read 2026-10-12: [Elastic Load Balancing pricing](https://aws.amazon.com/elasticloadbalancing/pricing/) ($0.0225 per ALB-hour, $0.008 per LCU-hour, as used in the page's US-East-1 worked examples; "You are charged only on the dimension with the highest usage"); [Amazon VPC pricing](https://aws.amazon.com/vpc/pricing/), public IPv4 tab ($0.005 per in-use public IPv4 address per hour, and the page's own example counts "one Elastic load balancer with two in-use public IPv4 address"); Fargate from Lab 04 Exercise 4 ($9.01 per task-month). The ELB pricing page lists its rates only inside its examples in the text I could read, so these figures should be re-checked against the console's pricing calculator before they are quoted to finance.

One LCU is 25 new connections/s, 3,000 active connections/min, 1 GB processed per hour (container and IP targets), or 1,000 rule evaluations/s. With 10 or fewer rules, rule evaluations are ignored; this listener has 2.

**Assumptions** (labelled; replace with real figures): normal traffic averages 1 request/s, each on a new connection held for 60 s, with 5 KB responses; enrolment week uses Lab 04's estimate, 67.5 requests/s for the 1.25-hour Monday window, which happens 52/12 x 1.25 = 5.42 hours a month.

| Dimension | Normal (1 req/s) | Enrolment peak (67.5 req/s) |
|---|---|---|
| New connections | 1 / 25 = **0.040 LCU** | 67.5 / 25 = **2.70 LCU** |
| Active connections | 60 / 3,000 = 0.020 | 4,050 / 3,000 = 1.35 |
| Processed bytes | 18 MB/h = 0.018 | 1.22 GB/h = 1.22 |
| Rule evaluations | ignored (2 rules) | ignored |

**For a low-traffic API, new connections dominate, not processed bytes**, because the requests and responses are small and each new connection costs LCUs whatever its size.

| Item | Derivation | Monthly |
|---|---|---|
| ALB hourly charge | 730 h x $0.0225 | $16.43 |
| Two public IPv4 addresses (one per AZ node) | 2 x 730 h x $0.005 | $7.30 |
| **Idle total** (no requests, 0 LCU) | | **$23.73** |
| LCUs, normal traffic | 0.04 LCU x 730 h x $0.008 | $0.23 |
| LCUs, enrolment week extra | (2.70 - 0.04) LCU x 5.42 h x $0.008 | $0.12 |
| **Under load total** | | **$24.07** |
| For comparison: two Fargate tasks (Lab 04) | 2 x $9.01 | $18.02 |

The load balancer costs more than the two tasks behind it, and almost all of it is fixed: traffic adds about 35 cents a month. An internal load balancer would remove the $7.30 of public addresses (idle $16.43, under load $16.77). Data transfer out to the internet is charged separately and is not included.

### The HTTPS plan

Opening a port and making something listen on it are separate. **What opens the port** is the security group rule: `usms-alb-sg` already admits tcp/443 from `0.0.0.0/0` (Step 4's "Your turn"), and that alone serves nothing. **What makes something listen** is an HTTPS listener with a certificate.

In order:

1. **A domain name the university controls**, for example `enrol.example.edu.bt`. *Outside AWS* (the university's registrar and DNS), or registered through Route 53 at the registrar's price. The load balancer's generated name cannot carry the university's certificate.
2. **A public certificate from AWS Certificate Manager** for that name. *Free from AWS*: "Public certificate (non-exportable): No cost" for services integrated with ACM ([ACM pricing](https://aws.amazon.com/certificate-manager/pricing/)). The surprising fact: the certificate itself costs nothing; only exportable certificates ($7.00 per name) are charged.
3. **DNS validation**: ACM provides a CNAME record to add to the domain's DNS ([DNS validation](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html)). *Outside AWS* if the university's DNS is hosted elsewhere. ACM renews automatically while the CNAME stays in place; unvalidated after 72 hours, the request times out.
4. **An HTTPS:443 listener** on `usms-enrolment-alb` with that certificate and a security policy, default action forward to `usms-enrolment-tg`. "When you create a secure listener, you must specify a security policy and a certificate" ([HTTPS listener](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/create-https-listener.html)); the documented example policy is `ELBSecurityPolicy-TLS13-1-2-2021-06`. *Free* (no charge beyond the load balancer). **This is the step that makes something listen on 443.**
5. **A DNS record** pointing the domain name at the load balancer (CNAME, or a Route 53 alias). *Outside AWS* if the DNS is external.
6. **Change the port-80 listener's default action from `forward` to `redirect`**, so plaintext requests never reach the application ([rule action types](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/rule-action-types.html)):

   ```json
   [{ "Type": "redirect",
      "RedirectConfig": { "Protocol": "HTTPS", "Port": "443", "Host": "#{host}",
                          "Path": "/#{path}", "Query": "#{query}", "StatusCode": "HTTP_301" } }]
   ```

   The `/alb-health` fixed-response rule at priority 10 can stay on port 80, since it carries no user data.

Not tested here: I did not probe ACM on this Floci build, and Floci's load balancer has no public DNS, so this plan is **conceptual**.

### The tidy-up

The two practice objects from Exercise 1, deleted in dependency order: the rule first, because a target group cannot be deleted while a rule forwards to it.

> **DANGER**
> **What will be deleted:** the listener rule at priority 20 (`/results`, `/results/*` -> `usms-results-tg`), tagged `Service=results`.
> **What depends on it:** nothing. No service is registered behind it and its target group was empty.
> **Reversible?** Yes. The Exercise 1 commands and the two `templates/lab-05-ex1-*` documents recreate it.
> **Effect on later labs:** none. It is not in `configs/lab-05.env`, and `verify-lab-05.sh` asserts the priority-10 rule, not this one.

```bash
RULE=$(aws elbv2 describe-rules --listener-arn "$USMS_ALB_LISTENER_ARN" \
  --query 'Rules[?Priority==`"20"`].RuleArn | [0]' --output text)
aws elbv2 delete-rule --rule-arn "$RULE"
```

> **DANGER**
> **What will be deleted:** the target group `usms-results-tg`.
> **What depends on it:** nothing, once the priority-20 rule is gone. It has 0 targets and no service names it.
> **Reversible?** Yes. Re-running Exercise 1 recreates it (with a new ARN).
> **Effect on later labs:** none. Lab 06's metric names `usms-enrolment-tg`, which is untouched.

```bash
TG=$(aws elbv2 describe-target-groups --names usms-results-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 delete-target-group --target-group-arn "$TG"
```

Observed ([evidence/lab-05-ex4-tidyup.txt](evidence/lab-05-ex4-tidyup.txt)): both ARNs were looked up first (the rule's `Service` tag read `results`, the target group had 0 targets). After `delete-rule` the listener had rules `10` and `default`; after `delete-target-group`, `describe-target-groups --names usms-results-tg` returned TargetGroupNotFound. `usms-enrolment-tg` and the `/alb-health` rule are untouched. Unlike security group revokes in Step 13, both deletions really took effect on Floci.

`verify-lab-05.sh` afterwards: **PASS=52 FAIL=3**, the same three `[floci]` checks as before, so nothing the lab asserts was affected. `usms-lb-report.sh` now prints the pre-Exercise 1 table (the `/alb-health` rule and the default), which is Exercise 3's "before Exercise 1" case.

---

## Exercise 5 - Integration: the ResourceLabel hand-off to Lab 06

`scripts/utilities/usms-resource-label.sh [load-balancer-name] [target-group-name]` (defaults `usms-enrolment-alb`, `usms-enrolment-tg`) looks both ARNs up from the API by name, never from `configs/lab-05.env`, and prints:

```
app/usms-enrolment-alb/794a0732ca6d4a09/targetgroup/usms-enrolment-tg/2414901868f64c56
```

**Why the two suffixes are cut differently.** The label keeps one resource-type word and drops the other. For the load balancer it takes everything after `:loadbalancer/` (the word `loadbalancer` is dropped): `${LB_ARN#*:loadbalancer/}`. For the target group it takes everything after the last `:`, which keeps the word `targetgroup`: `${TG_ARN##*:}`. Both are shell parameter expansion: `#` removes the shortest matching prefix, `##` the longest.

**Validation before printing** (the only check possible without a scaling policy): exactly six `/`-separated segments; the first is the literal `app`; segment 2 is the load balancer name; segment 4 is `targetgroup`; segment 5 is the target group name; both ID segments non-empty. Any failure prints a reason on stderr and exits 1 with nothing on stdout, so a caller cannot use a bad label by accident.

**Why `app` is there:** it is the load balancer type in its ARN (`loadbalancer/app/...` for an Application Load Balancer); a Network Load Balancer's ARN has `net` there, and `ALBRequestCountPerTarget` only applies to Application Load Balancers.

Observed ([evidence/lab-05-ex5-label.txt](evidence/lab-05-ex5-label.txt)): the same label from the repository and from `~`, and with explicit names; a wrong load balancer or target group name prints `no load balancer named no-such-alb` (or the target group equivalent) and exits 1. The script contains no reference to an access key (grep count 0). Timestamps in this exercise come from `python3`, not `date -d`/`date -v`.

`USMS_ALB_RESOURCE_LABEL` was appended to `configs/lab-05.env` by running the script, not by typing it. The file now has **16 exports**; the empty-value check finds none, and the only `None` remains the documented grace period.

**The readiness file** ([evidence/lab-05-lab04c-readiness.txt](evidence/lab-05-lab04c-readiness.txt)):

```
resource label           : app/usms-enrolment-alb/794a0732ca6d4a09/targetgroup/usms-enrolment-tg/2414901868f64c56
target group ARN         : arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/usms-enrolment-tg/2414901868f64c56
load balancer ARN        : arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/usms-enrolment-alb/794a0732ca6d4a09
scalable resource ID     : service/usms-ecs-cluster/usms-enrolment-svc
scalable dimension       : ecs:service:DesiredCount
current desired count    : 2
recommended metric       : ALBRequestCountPerTarget, because the enrolment API is I/O-bound (CPU stays low while requests queue) and requests per target measures the actual load per task directly, now that a target group exists to count them.
```

From those lines, Lab 06's call is `put-scaling-policy --service-namespace ecs --resource-id service/usms-ecs-cluster/usms-enrolment-svc --scalable-dimension ecs:service:DesiredCount --policy-type TargetTrackingScaling` with `PredefinedMetricType=ALBRequestCountPerTarget` and `ResourceLabel=$USMS_ALB_RESOURCE_LABEL`.

**The measurement** ([evidence/lab-05-ex5-measure.txt](evidence/lab-05-ex5-measure.txt)):

- **As specified, not measurable on this build.** After `--force-new-deployment` I polled for 138.7 s: `deployments` stayed empty (0) and the same two healthy targets stayed, so "exactly one deployment and a stable target list" can never become true, and no capacity was replaced (the same Floci limitation as Step 14).
- **Stand-in, measured: 33.7 s.** I stopped one task with `ecs stop-task` and timed until the target group held two healthy targets again: a new task was started, registered by the service, and passed two health checks.
- **For real AWS**, the course text gives 20 to 60 s for a Fargate task to start; a rolling replacement adds the 30 s deregistration delay and the health check's 2 x 30 s. That puts a full replacement at roughly 1.5 to 2.5 minutes, so Lab 06's scale-in cooldown should be longer than that.

---

## Floci limitations found in the exercises

| Limitation | Seen in | What real AWS does |
|---|---|---|
| `describe-rules` puts path values only in `PathPatternConfig.Values`, `Values` is `[]` | Ex 1, 3 | Returns the values in both |
| `--force-new-deployment` replaces no tasks and reports no deployments | Ex 5 | Rolling replacement, one PRIMARY deployment when finished |
| Group source of a security group rule not returned | Ex 2 | Returned in `UserIdGroupPairs` |
| A single group-sourced rule cannot be revoked (so the "both rules present" case was not tested live) | Ex 2 | `revoke-security-group-ingress` removes exactly that rule |
| No public DNS for the load balancer, ACM not probed | Ex 4 | Public DNS name; ACM issues and renews certificates |
