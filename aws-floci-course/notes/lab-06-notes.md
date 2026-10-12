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
