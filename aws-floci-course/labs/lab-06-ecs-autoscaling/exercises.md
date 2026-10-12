# Lab 06 - Independent Lab Exercises

Environment: Floci v1.5.34, AWS CLI v2.31.35. **Support path C**: this Floci build has no Application Auto Scaling (every call returns `UnknownOperationException`; see the README). The lab's path table says that on path C you do Exercises 4 and 5 and the review questions. Exercises 1 to 3 cannot be done here, for the reason given under each.

Labels used throughout: **Observed** (seen in command output), **Conceptual** (reasoned about real AWS, not run), **Floci limitation** (this emulator behaves differently from real AWS). Command output is in [`evidence/`](evidence/).

---

## Exercises 1 to 3 - not possible on this build

- **Exercise 1** (a memory target tracking policy and a scale-out-only policy) and **Exercise 2** (the scale-in half of step scaling) both create scaling policies with `put-scaling-policy`, which returns `UnknownOperationException`. Nothing was created, so nothing is left for Exercise 4 to tidy up.
- **Exercise 3** (a scaling report tool) reads scalable targets, policies and activities, none of which can be described. Exercise 5's `usms-scaling-history.sh` covers the same calls and shows what each returns on this build.

---

## Exercise 4 - Challenge: the enrolment-week capacity plan

*Written for the USMS project lead, with figures a finance team can check.*

### Is it solved?

Reactive auto scaling is good at following load that rises over several minutes: it adds tasks as the requests per task climb and removes them when the load falls, without anyone watching. It is bad at sudden spikes, because every decision waits for a metric to be published, an alarm to see three minutes of it, and new tasks to start and pass their health checks. So on its own it would not have saved last year's first twenty minutes: the spike would still land on the two tasks already running, and help would arrive about five minutes later. **The first twenty minutes must be covered by capacity we schedule in advance, not by capacity we react with.**

### Why forty times the traffic is a timing problem, not a capacity problem

**Time from 2 tasks to 10, reactively** (on real AWS; this build cannot run it):

| Delay | Where it comes from | Time |
|---|---|---|
| Metric published | load balancer `RequestCountPerTarget`, one-minute datapoints | up to 1 min |
| Alarm decides | target tracking's managed high alarm needs 3 consecutive datapoints over target | 3 min |
| Policy acts | Application Auto Scaling computes capacity and calls `ecs:UpdateService` | seconds |
| Tasks start | Fargate start-up, 20 to 60 s on real AWS (course figure); 12.8 s to running here, where no real image is pulled | 20 to 60 s |
| Tasks count | 2 health checks at 30 s (Lab 05 target group), inside the 60 s grace period (Lab 05) | about 60 s |
| **Total** | | **about 5 to 6 minutes** |

Target tracking computes capacity in proportion to the breach (capacity x metric / target), so at forty times the load it asks for far more than 10 in one decision, and the ceiling caps it at 10. The time is the same for one decision. A step policy (+1 or +3 per alarm, 60 s cooldown) would need three rounds to go from 2 to 10, so it would take longer still. My measured stand-in, `desiredCount` 2 to 4 directly, reached four healthy targets in **37.1 s** ([evidence](evidence/lab-06-scale-latency.txt)); it covers everything after Application Auto Scaling writes the number, not the 3 to 4 minutes before it.

**What the ceiling of 10 means at Step 9's target.** The requests policy aims for 1000 requests per target per minute, so 10 tasks are sized for 10 x 1000 = 10,000 requests a minute, which is **166.7 requests per second**. That is a throughput target, not the capacity limit. If one task can serve 25 requests per second (Lab 04's labelled assumption, never measured), 10 tasks can serve 250 per second at most.

**Is 40x a capacity problem?** Only if "normal" is large. With Lab 05's assumption of 1 request per second normally, 40x is 40 per second, or 2,400 a minute, which is 2.4 tasks at the 1000 target. With Lab 04's estimate of 67.5 per second at peak, it is 4,050 a minute, or 4.05 tasks. **Both fit well inside 10.** The capacity we need is modest; the problem is having it in place at 08:00 instead of 08:05.

### The ceiling, checked against Lab 02

Per the [VPC documentation on subnet sizing](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html), "the first four IP addresses and the last IP address in each subnet CIDR block are not available for your use": the network address, the VPC router, the DNS server, one reserved for future use, and the broadcast address.

| Subnet | Size | Reserved by AWS | Existing occupants (observed) | Free for tasks |
|---|---|---|---|---|
| `usms-private-subnet-a` 10.0.3.0/24 | 256 | 5 | `usms-db-01` (1 interface) | 250 |
| `usms-private-subnet-b` 10.0.4.0/24 | 256 | 5 | `usms-db-02` (1 interface) | 250 |

Each Fargate task in `awsvpc` mode takes one address, so the subnets could hold about **500 tasks**. The S3 endpoint is a gateway endpoint and takes no address. **Floci limitation:** `AvailableIpAddressCount` reads 251 in both subnets, so Floci does not count the database instances or the tasks.

**The real limit is a quota, not addresses.** The [ECS service quotas page](https://docs.aws.amazon.com/general/latest/gr/ecs-service.html) gives "Fargate On-Demand vCPU resource count: 6" per Region by default (adjustable, and "new AWS accounts might have initial lower quotas"). At 0.25 vCPU per task that is **24 tasks** for the whole account in us-east-1, shared with anything else running on Fargate. Tasks per service is 5,000. **The largest supportable ceiling today is 24**, and the ceiling of 10 is safe against both limits. Raising it beyond 24 needs a quota increase first.

### The capacity plan

The plan has four parts: scheduled floors for the known spikes, the same ceiling with headroom, the target value left alone until a load test says otherwise, and every change reversible in one command. The enrolment dates below use **the 14th of November 2026 as an example**, because the brief does not say which month or which three days the cohorts open; replace them with the real dates.

**1. Cohort days (40x in the first hour).** One pair of one-off actions per cohort day, starting 15 minutes before opening:

```bash
aws application-autoscaling put-scheduled-action --service-namespace ecs \
  --resource-id service/usms-ecs-cluster/usms-enrolment-svc --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name usms-enrolment-cohort1-open \
  --schedule "at(2026-11-14T07:45:00)" --timezone "Asia/Thimphu" \
  --scalable-target-action MinCapacity=6,MaxCapacity=12

aws application-autoscaling put-scheduled-action --service-namespace ecs \
  --resource-id service/usms-ecs-cluster/usms-enrolment-svc --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name usms-enrolment-cohort1-settle \
  --schedule "at(2026-11-14T09:30:00)" --timezone "Asia/Thimphu" \
  --scalable-target-action MinCapacity=4,MaxCapacity=10
```

Repeat for cohorts 2 and 3 with their dates. A floor of 6 (three tasks per Availability Zone) is 1.5 times the 4.05 tasks Lab 04's peak estimate needs, and 1.5 times the minimum 4 that would survive losing a zone. `MaxCapacity` 12 leaves the policy room above the floor and stays under the quota of 24. `at()` actions stay in the account after they fire, so delete them after enrolment.

**2. The three-week window (2x traffic).** The weekday morning action from Step 11 with a higher floor, limited to the window with `--start-time` and `--end-time`, plus its evening partner:

```bash
aws application-autoscaling put-scheduled-action ... --scheduled-action-name usms-enrolment-window-morning \
  --schedule "cron(45 7 ? * MON-FRI *)" --timezone "Asia/Thimphu" \
  --start-time 2026-11-14T00:00:00 --end-time 2026-12-05T00:00:00 \
  --scalable-target-action MinCapacity=4,MaxCapacity=10
aws application-autoscaling put-scheduled-action ... --scheduled-action-name usms-enrolment-window-evening \
  --schedule "cron(0 20 ? * MON-FRI *)" --timezone "Asia/Thimphu" \
  --start-time 2026-11-14T00:00:00 --end-time 2026-12-05T00:00:00 \
  --scalable-target-action MinCapacity=2,MaxCapacity=10
```

**3. Target values.** Leave CPU at 50 and requests at 1000 until the load test (below) tells us what one task can serve. If it shows less than about 17 requests per second per task (1000 a minute), lower the requests target before the 14th with one `put-scaling-policy` call (create-or-replace), and raise it back afterwards.

**4. The ceiling.** Keep 10 outside cohort days and 12 on them. Ask for a Fargate vCPU quota increase before the 14th only if the load test shows we need more than 24 tasks.

**Reversible in one command:** every scheduled action (`delete-scheduled-action`, or `put-scheduled-action` again, since it replaces); the bounds (`register-scalable-target`); the target value (`put-scaling-policy`). The quota increase is not: it is a support request and is not reversed by the account.

### Monthly cost

Sources: [AWS Fargate pricing](https://aws.amazon.com/fargate/pricing/), US East (N. Virginia) Linux/x86, "$0.000011244 per vCPU second" and "$0.000001235 per GB per second", which is $0.04048 per vCPU-hour and $0.004446 per GB-hour, billed per second with a one-minute minimum. [Amazon CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/): $0.30 per custom metric per month, $0.10 per standard-resolution alarm metric per month, and a free tier of 10 custom metrics, 10 alarm metrics and 1 million API requests a month. Both pages give these rates in their worked examples rather than a table I could read, so re-check them in the AWS Pricing Calculator before submitting.

**Task size.** `configs/lab-04.env` records 256 CPU and 512 MiB, revision 1's size. The service actually runs `usms-enrolment:2`, which Lab 04 Exercise 2 raised to 1024 MiB. Both are shown.

| Item | Derivation | 512 MiB | 1024 MiB (running) |
|---|---|---|---|
| One task-hour | 0.25 x $0.04048 + GB x $0.004446 | $0.012343 | $0.014566 |
| Cohort days | 3 days x 1.75 h (07:45 to 09:30) x 2 tasks above the window's floor of 4 (floor 6) = 10.5 task-hours | $0.13 | $0.15 |
| Three-week window | 15 weekdays x 12.25 h (07:45 to 20:00) x 2 extra tasks = 367.5 task-hours | $4.54 | $5.35 |
| **Extra Fargate for enrolment** | 378 task-hours | **$4.67** | **$5.51** |
| CloudWatch alarms | 4 managed (2 per target tracking policy) + 1 queue alarm = 5 x $0.10 | $0.50 a month | |
| CloudWatch custom metric | `USMS/Enrolment EnrolmentQueueDepth`, 1 x $0.30 | $0.30 a month | |
| PutMetricData | one call a minute = about 43,200 a month, inside the 1 million free requests | $0 | |

If the account is within CloudWatch's free tier (10 alarms, 10 custom metrics), the CloudWatch line is $0. Assumptions: the three cohort days fall on weekdays inside the window; the window has 15 weekdays; nothing else in the account uses the free tier; the policies never scale above the scheduled floors (any reactive scale-out adds about $0.012 to $0.015 per task-hour on top). The whole enrolment period costs about five dollars of extra compute ($4.67 to $5.51), against last year's lost afternoon.

### What I need from you

1. **The three cohort dates and the opening time** on each, so the scheduled actions are not built on my example dates.
2. **Last year's real request numbers** from analytics: requests per second in a normal hour, and in the busiest minute of a cohort morning. Every figure above uses labelled assumptions in their place.
3. **Time and approval for a load test**, to measure how many requests per second one task can serve before its response time degrades. Nobody has taken this measurement, and every number in this plan (the target of 1000, the floor of 6, the ceiling of 10) depends on it.

### The tidy-up

Exercises 1 and 2 could not create anything on this build, so there is nothing to delete. These are the commands I would run on real AWS, in dependency order: policies first (deleting a policy also deletes its managed alarms), then my own alarm from Exercise 2, which would otherwise point at a policy that no longer exists.

> **DANGER**
> **What will be deleted:** the target tracking policy `usms-enrolment-memory-target-tracking` (Exercise 1) and its two managed alarms.
> **What depends on it:** nothing; the CPU and requests policies are separate and stay.
> **Reversible?** Yes. Exercise 1's `put-scaling-policy` recreates it.
> **Effect on later labs:** none. It is not in `configs/lab-06.env`.

```bash
aws application-autoscaling delete-scaling-policy --service-namespace ecs \
  --resource-id service/usms-ecs-cluster/usms-enrolment-svc --scalable-dimension ecs:service:DesiredCount \
  --policy-name usms-enrolment-memory-target-tracking
```

> **DANGER**
> **What will be deleted:** Exercise 2's scale-in step policy and the alarm that drives it.
> **What depends on it:** nothing kept; `usms-enrolment-queue-step-out` and `usms-enrolment-queue-high` are separate and stay.
> **Reversible?** Yes. Exercise 2's commands recreate both.
> **Effect on later labs:** none.

```bash
aws application-autoscaling delete-scaling-policy ... --policy-name <exercise-2 scale-in policy>
aws cloudwatch delete-alarms --alarm-names <exercise-2 queue-low alarm>
```

**Not executed:** `describe-scaling-policies` cannot run, and `describe-alarms` lists only `usms-enrolment-queue-high`, which is kept. `verify-lab-06.sh` is unchanged at **PASS=30 FAIL=20** (all `[floci]`).

---

## Exercise 5 - Integration: the hand-off to Lab 10

`scripts/utilities/usms-scaling-history.sh` exports the service's scaling configuration and history as one JSON document, `outputs/lab-06-scaling-history.json`.

- **Discovers every identifier:** the resource ID is the service ARN's resource part (`${SVC_ARN##*:}`); policies, scheduled actions and activities are read for that resource ID; alarms are the ones each policy lists, plus any alarm whose actions name a policy on this resource, plus alarms on the `USMS/Enrolment` metric. No policy, alarm or resource ID is hard-coded.
- **Survives a missing service:** each section whose call fails is written as `{"error": "<message>"}` instead of aborting, so the document still describes everything that exists. It uses `set -uo pipefail` without `-e` for that reason.
- **Top-level fields:** `generated` (UTC, from `python3`) and `resourceId`; validated with `python3 -m json.tool`.

Observed: **1,905 bytes, valid JSON**, identical from the repository and from `~`. On this build the scalable target, policies, scheduled actions and activities sections each hold the `UnknownOperationException` message; the service section (desired 2, running 2, `usms-enrolment:2`) and the `usms-enrolment-queue-high` alarm (state OK, no actions) are real.

**Scale-out latency** ([evidence](evidence/lab-06-scale-latency.txt)): re-registering `MinCapacity` to 4 is impossible here, so I raised `desiredCount` from 2 to 4 with `update-service`:

```
start timestamp            : 2026-10-12T18:03:10.890Z
capacity before / after    : 2 / 4
elapsed to running (s)     : 12.8
4 healthy targets timestamp: 2026-10-12T18:03:48.015Z
elapsed_seconds            : 37.1
floor restored             : desiredCount 2 (no scalable target exists, so MinCapacity was never changed)
```

For real AWS, the course text gives 20 to 60 s for a Fargate task to start; Floci pulls no image over the NAT gateway, so its 12.8 s is a lower bound.

`configs/lab-06.env` gained `USMS_SCALING_HISTORY_FILE` and `USMS_SCALE_LATENCY_SECONDS=37.1`, both derived (the latency read from the latency file, not typed). The file now has **24 exports**, with no empty values and no `None`.

**The Lab 10 readiness file** ([evidence](evidence/lab-06-lab10-readiness.txt)):

```
history file             : outputs/lab-06-scaling-history.json (1905 bytes, valid JSON)
scale-out latency (s)    : 37.1
task role ARN            : arn:aws:iam::000000000000:role/usms-ecs-task-role (attached: USMSStudentDataReadWrite)
bucket ARN (from policy) : arn:aws:s3:::usms-student-data
permissions on the bucket: Allow s3:ListBucket and s3:GetBucketLocation on the bucket, Allow s3:GetObject,
                           s3:PutObject and s3:DeleteObject on its objects, and an explicit Deny on s3:DeleteBucket.
head-bucket exit code    : 254
head-bucket output       : An error occurred (404) when calling the HeadBucket operation: Not Found
```

The bucket ARN was read with `get-policy` (default version `v1`) and `get-policy-version`, not typed. The policy has two `Resource` entries: `arn:aws:s3:::usms-student-data` (the bucket) and `arn:aws:s3:::usms-student-data/*` (its objects); I recorded the bucket. `head-bucket` was captured with its exit code and did not abort the script.

**After Lab 10's Step 1:** once `usms-student-data` exists, `head-bucket` returns exit code 0 with no output. At that moment the Allow statements in `USMSStudentDataReadWrite`, attached to `usms-ecs-task-role` since Lab 04 and to `usms-ec2-app-role` since Lab 03, stop naming a bucket that does not exist and start granting real access, for both roles at the same instant.

---

## Floci limitations found in the exercises

| Limitation | Seen in | What real AWS does |
|---|---|---|
| No Application Auto Scaling at all | Ex 1 to 5 | Full service |
| `AvailableIpAddressCount` ignores the database instances and the tasks | Ex 4 | Counts every interface in the subnet |
| Task start in 12.8 s with no image pull | Ex 4, 5 | 20 to 60 s on real Fargate |
