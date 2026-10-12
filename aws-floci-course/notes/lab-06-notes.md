# Lab 06 notes

## Support path: C (no Application Auto Scaling)
Probed on Floci v1.5.34, 2026-10-12 (outputs/lab-06-support-probe.txt).
- Application Auto Scaling: NOT implemented. describe-scalable-targets, describe-scaling-policies, describe-scheduled-actions and describe-scaling-activities all return UnknownOperationException (AnyScaleFrontendService.<Operation>). The two "SUPPORTED" lines (register-scalable-target, put-scaling-policy) are --generate-cli-skeleton probes, which the CLI answers offline; real calls to both, made against a resource that does not exist so nothing could be created, also return UnknownOperationException.
- Same result as Lab 04's probe (notes/lab-04-notes.md), so this build has never had the service.
- CloudWatch: describe-alarms answers (empty list); put-metric-alarm, put-metric-data, set-alarm-state, list-metrics known to the CLI.
- IAM: AWSServiceRoleForApplicationAutoScaling_ECSService does not exist (NoSuchEntity).
- ECS and ELBv2: supported, as in Labs 04 and 05.
Per the lab's path table, path C means: tell the instructor, and do Exercises 4 and 5 and the Section 14 review questions.

## Pre-lab verification (Step 2)
verify-lab-02 PASS=33 FAIL=0; verify-lab-03 PASS=32 FAIL=5 (all [floci]); verify-lab-04 PASS=39 FAIL=1 (the [floci] read-back; Lab 05 Exercise 2 applied); verify-lab-05 PASS=52 FAIL=3 (all [floci]), saved to outputs/lab-06-pre-verify-05.txt.
Service at baseline: desired 2, running 2, pending 0, one loadBalancers entry; deployments null (Floci, as in Labs 04 and 05).
Configs: task memory reads 512 (the lab's example shows 1024, from its own revision 2; my configs/lab-04.env records revision 1's value); grace period None (Lab 05 Step 10 limitation).
All four Lab 3 instances running at the start (checked because Lab 05's restart had stopped them).

## Path C plus what this build supports
Chosen so the parts of the lab that Floci does implement (CloudWatch metric and alarm, ECS) are still built and tested, with every Application Auto Scaling step recorded as a request body that is ready to run on real AWS.

## Step 4: service-linked role - not created
create-service-linked-role --aws-service-name ecs.application-autoscaling.amazonaws.com returned UnsupportedOperation ("Operation CreateServiceLinkedRole is not supported"); get-role then returned NoSuchEntity. I did not fake it with create-role: a hand-made role would have path / instead of /aws-service-role/ecs.application-autoscaling.amazonaws.com/, a trust policy I wrote, and no AWS-owned permissions, so it would not be the same object.
On real AWS this role is what calls ecs:UpdateService when a policy fires, and CloudTrail names it as the caller.

## Steps 5 to 9, 11 and 13: not runnable (path C)
register-scalable-target, put-scaling-policy, put-scheduled-action and every describe- call return UnknownOperationException. The request bodies are written and validated instead (labs/lab-06-ecs-autoscaling/evidence/lab-06-templates.txt):
- templates/lab-06-target-tracking-cpu.json: ECSServiceAverageCPUUtilization, target 50.0, out 60, in 300, DisableScaleIn false (quoted heredoc, 0 literal $).
- templates/lab-06-target-tracking-requests.json: ALBRequestCountPerTarget, target 1000.0, ResourceLabel re-derived by usms-resource-label.sh and identical to USMS_ALB_RESOURCE_LABEL (6 segments; unquoted heredoc, 0 literal $).
- templates/lab-06-step-scaling-out.json: ChangeInCapacity, Average, cooldown 60, steps [0,100) +1 and [100, open) +3.
- templates/lab-06-suspended-state.json: scale-in suspended only (the safe direction).

## Step 10: custom metric and alarm - built
put-metric-data published 3, 5, 4 to USMS/Enrolment EnrolmentQueueDepth (Service=enrolment); list-metrics shows it.
usms-enrolment-queue-high created: Average >= 100, period 60, 1 evaluation, notBreaching, tagged Lab=06. It was created WITHOUT --alarm-actions, because the step policy's ARN cannot exist on this build (on real AWS the policy must exist first, or put-metric-alarm fails with "Invalid metrics or alarm actions"). Initial state INSUFFICIENT_DATA.

## Step 12: fire the alarm - observed, and nothing scaled
Before: desired 2, running 2, pending 0; describe-scaling-activities UnknownOperationException.
Published 260 three times, 5 s apart. get-metric-statistics for that minute: Average 132.0, Maximum 260.0 - not 260, because the three Step 10 datapoints (3, 5, 4) fell in the same minute. 132 >= 100 is still a breach.
Real AWS prediction (written before looking): breach of 160 above the threshold falls in the open-ended step, +3, desired 2 -> 5.
Floci limitation: the alarm is never evaluated. Six polls over 80 s read INSUFFICIENT_DATA with reason "Unchecked". Real CloudWatch evaluates every minute and would have gone to ALARM.
set-alarm-state ALARM worked (StateValue ALARM, my reason, timestamp). desiredCount stayed 2 for six polls over 55 s: correct, because the alarm has no action and no policy exists. describe-alarm-history is unsupported ("not supported by CloudWatch Query"). The alarm was set back to OK afterwards; Floci will not re-evaluate it.
Conclusion: nothing other than me moved desiredCount, and I make no claim that anything did.

## Exercise 5 stand-in: scale-out latency, measured
Raising MinCapacity by re-registering is impossible here, so desiredCount was raised 2 -> 4 with update-service (labs/lab-06-ecs-autoscaling/evidence/lab-06-scale-latency.txt): running 4 after 12.8 s, four healthy targets after 37.1 s; restored to 2 (running 2, healthy 2). This measures ECS plus the target group, which is everything after Application Auto Scaling writes the number; it leaves out the alarm evaluation and policy invocation that real scaling adds in front.

## Step 16: configs/lab-06.env
22 exports, all looked up. Values that would come from Application Auto Scaling or the service-linked role read not-created (the lab's own convention for unsupported policies), so the file records what exists: USMS_SCALE_MIN, USMS_SCALE_MAX, the three policy ARNs and USMS_ASA_SLR. The alarm name is looked up and present. Resource ID service/usms-ecs-cluster/usms-enrolment-svc.

## Step 17: the "stale string" repair - deliberately not run
The lab replaces every lab-04-cleanup.sh with lab-06-cleanup.sh in the Lab 04 and Lab 05 cleanup scripts. In my lab-05-cleanup.sh the wrong line was already fixed in Lab 05; the two remaining mentions ("run BEFORE lab-04-cleanup.sh", "lab-04-cleanup.sh may now run") are correct, and a blanket replace would make them wrong. lab-04-cleanup.sh does not contain the string.

## Section 8: verify-lab-06.sh
As the lab gives it: PASS=22 FAIL=20. Failures: 19 that depend on Application Auto Scaling, plus the outputs/.gitkeep false positive (same as Labs 2, 4 and 5).
A silent pass: "NO suspension switch was left true" passed because there is no scalable target - nothing is suspended because nothing exists. It now requires the target to exist first, so it fails honestly as [floci].
Adapted: every Application Auto Scaling check labelled [floci] and kept as written; stand-ins that can fail - resource ID three segments and equal to the service ARN suffix; bounds recorded as not-created rather than invented; the three request bodies' exact contents (and the ResourceLabel re-derived live); the alarm's statistic, operator, threshold, period, evaluations and missing-data treatment, and that it was not left in ALARM; running equals desired with nothing pending. Git hygiene ignores outputs/.gitkeep.
Result: PASS=30 FAIL=20, all 20 [floci].
lab-06-cleanup.sh: copied from the lab, passes bash -n, NOT run. On this build its Application Auto Scaling calls would all fail; only the alarm deletion would do anything.

## Review questions

All answers are conceptual on this build: no scalable target, policy or scheduled action could be created (path C).

**1. From one click to one new task, and what auto scaling changes.**
The nine lines: (1) a student clicks Register in the portal on usms-web-01; (2) the request reaches usms-enrolment-alb's listener on HTTP:80; (3) the default action forwards it to a target in usms-enrolment-tg; (4) a task in a private subnet, admitted by usms-enrolment-sg from usms-alb-sg, serves it; (5) the load balancer counts it in AWS/ApplicationELB RequestCountPerTarget for that target group; (6) the target tracking policy's alarm compares the per-target count with 1000 per minute and goes to ALARM; (7) Application Auto Scaling computes a new capacity and, through the service-linked role, calls ecs:UpdateService with a new desiredCount; (8) ECS starts tasks in the private subnets until runningCount matches; (9) the service registers each new task in usms-enrolment-tg and, after its health checks pass, the load balancer sends it requests. This lab owns lines 6 and 7 and the integer in line 8 - the alarm, the policy and the number. The other six needed no change because they already worked for any number of tasks: the load balancer forwards to whatever is registered, the service registers whatever it starts, and the security groups name groups rather than addresses. Auto scaling changes one thing about the application: who decides how many copies of it run, and when.

**2. Why the full ARN is rejected as --resource-id.**
The resource ID is a constructed string that names the scalable thing within a namespace, not an ARN: for ECS it is service/<cluster>/<service>, which is exactly the resource part of the service ARN after the last colon. Application Auto Scaling uses a constructed string because it scales nine different kinds of resource whose ARNs have nothing in common, so each namespace defines its own short form plus a scalable dimension. In ecs it is service/usms-ecs-cluster/usms-enrolment-svc with ecs:service:DesiredCount; in dynamodb it is table/<table> (or table/<table>/index/<index>) with dynamodb:table:ReadCapacityUnits; in lambda it is function:<function>:<alias> with lambda:function:ProvisionedConcurrency. The other constructed identifier in this architecture is the ResourceLabel for ALBRequestCountPerTarget, app/<alb>/<id>/targetgroup/<tg>/<id>, built from the load balancer ARN (everything after loadbalancer/) and the target group ARN (everything after the last colon, keeping targetgroup); Lab 05 Exercise 5's script derives it.

**3. Registration raising the count.**
The scalable target made the change: registering bounds is itself an instruction that desiredCount must lie between them, so Application Auto Scaling raises a service at 1 to 2 immediately. A policy changes the count only in response to an alarm, inside the bounds, and leaves a scaling activity naming the alarm and the policy; a registration change is an administrative act whose activity cause names the registration, not a metric. At 3 a.m. an on-call engineer sees errors climbing during a batch run and, rather than wait for an alarm, re-registers the target with --min-capacity 6: within a minute there are six tasks and the floor stops any scale-in. The person at 8 a.m. finds describe-scalable-targets showing MinCapacity 6 instead of 2, a scaling activity at 03:12 with a cause naming the min capacity change, and a CloudTrail RegisterScalableTarget event with the engineer's identity - and the incident note should say when the floor goes back to 2, because nothing will lower it automatically.

**4. Managed alarms against my own alarm.**
The two TargetTracking- alarms belong to the policy: Application Auto Scaling creates them, recreates them when the policy changes, overwrites any edit at the next put-scaling-policy, and deletes them with the policy; if one is deleted by hand the policy silently stops scaling in that direction while still listing it. usms-enrolment-queue-high is mine: I chose the metric, statistic, threshold, period and missing-data treatment, it survives policy changes, and it can have other actions (an SNS notification to the on-call phone), which a managed alarm cannot. The case for TreatMissingData breaching: the queue depth is published by the application, so if the publisher dies the metric goes silent exactly when nothing is draining the queue, and treating silence as a breach adds capacity instead of assuming all is well. If I were right but wrong in practice, every routine publisher restart or deployment gap would add one to three tasks, which then sit idle until a scale-in policy (which this lab does not have for the step policy) removes them, and the alarm would fire in quiet periods, teaching people to ignore it.

**5. Why reactive scaling misses the first minutes.**
Delays, in order: the metric is published once a minute (Container Insights for CPU, the load balancer for RequestCountPerTarget); the managed alarm needs three consecutive one-minute datapoints above target (set by target tracking, not configurable) - about 3 minutes; Application Auto Scaling invokes the policy within seconds and ECS accepts the new count; a Fargate task takes 20 to 60 seconds to start (measured here as 12.8 s to running on Floci, which does not pull a real image over the NAT gateway); the target group then needs 2 healthy checks at 30 s (target group settings, Lab 05), and on real AWS ECS ignores the task's target health for the 60 s grace period (service setting). That is roughly 4 to 5 minutes from the spike to new capacity serving, all of it absorbed by the tasks already running. Consequences: the minimum capacity is a latency decision, which justifies MinCapacity 2 (one task per AZ) and raising the floor rather than trusting the policy; scale out eagerly and in reluctantly, which justifies ScaleOutCooldown 60 against ScaleInCooldown 300; and a spike you can predict must be scheduled, which justifies the 07:45 morning action - the only form of scaling that can be early.

**6. Two policies disagreeing.**
With CPU at 50 and requests at 1000 on one target, Application Auto Scaling scales out if either policy asks for more capacity and scales in only if every policy agrees the capacity can fall, so the larger answer always wins. The rule is asymmetric because the cost of the two mistakes is asymmetric: too much capacity costs money for a few minutes, too little drops requests. Two target tracking policies on the same metric are a fault because they compute capacity from the same signal with different targets, so the stricter one always wins and the other is dead configuration that misleads the reader. A step policy and a target tracking policy on one metric are the same mistake with more flapping: the target tracking policy scales in towards its target while the step policy's alarm, on the same numbers, scales out, and the two take turns - which is why the step policy here watches a different metric (queue depth).

**7. ALBRequestCountPerTarget against CPU.**
Three reasons it beats CPU for the enrolment API: the API is I/O-bound, waiting on the database, so CPU stays low while requests queue; requests per target measures the demand itself rather than a side effect of it, so its value falls predictably as tasks are added; and it reacts to load the moment requests arrive at the load balancer, before any task is busy enough to show it. CPU is better for compute-bound work - report generation, PDF rendering, image processing, encryption - where each request's cost varies and CPU is the real limit. ALBRequestCountPerTarget would scale this service badly if requests became very unequal in cost (one heavy "confirm enrolment" worth hundreds of "list modules"), if the bottleneck moved to the database so that more tasks only add load to it, or if work arrived without passing the load balancer; TargetResponseTime (latency rising while requests per target stay flat) and the database's own CPU and connections would have warned first.
