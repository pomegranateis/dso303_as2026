# Lab 05 notes

## Support path: A, with a data path reachable only inside Floci's Docker network (confirmed at Steps 11 and 12)
Probed on Floci 2026-10-12 (labs/lab-05-ecs-alb/evidence/lab-05-support-probe.txt).
- ELBv2: all six probes answered. describe-load-balancers and describe-target-groups return empty lists; describe-account-limits returns real limits (50 ALBs, 3000 target groups, 100 rules per ALB).
- ECS update-service and describe-services: supported.
- Path A requires Step 5 to return an ARN; it becomes B if targets never become healthy or Step 12's curl does not connect.

## Floci limitation: ELBv2 does not validate ARNs
describe-listeners --load-balancer-arn probe returned {"Listeners": []}.
Real AWS rejects a malformed ARN with ValidationError. On Floci a typo in an ARN looks like "no listeners", so every ARN in this lab is captured with $(...) and read back, never typed.

## Pre-lab verification (Step 2)
verify-lab-02 PASS=33 FAIL=0. verify-lab-03 PASS=32 FAIL=5 (all [floci], unchanged since Lab 3).
verify-lab-04 PASS=38 FAIL=1 (the [floci] group-source read-back, unchanged since Lab 04), saved to labs/lab-05-ecs-alb/evidence/lab-05-pre-verify-04.txt.
The lab asks for FAIL=0 before starting; the remaining failures are documented Floci limitations, not broken resources.

## Step 4: usms-alb-sg
usms-alb-sg (Tier=edge) admits tcp/80 from 0.0.0.0/0 (policies/usms-alb-sg-ingress.json). It is the only 0.0.0.0/0 ingress rule in the course and is deliberate: an internet-facing load balancer must accept the internet, and it forwards only to the target group, whose tasks admit only this group.
Your turn: tcp/443 from 0.0.0.0/0 added from policies/usms-alb-sg-ingress-https.json. Read-back shows two inbound rules (80 and 443, both 0.0.0.0/0, FromGroup null) and one outbound rule.

HTTPS still serves nothing: a security group rule opens a port but does not make anything listen on it. The two missing things are an HTTPS listener on 443 and the TLS certificate that listener must present. The certificate AWS can give for free through AWS Certificate Manager, but only for a domain name I can prove I own, and that domain I have to obtain from a registrar, because the load balancer's generated *.elb.amazonaws.com name cannot carry my own certificate.

## Step 5: usms-enrolment-alb
create-load-balancer returned an ARN (app/usms-enrolment-alb/794a0732ca6d4a09), so path A holds so far.
Read-back: active, application, internet-facing, ipv4, usms-vpc, two AZs (us-east-1a subnet-d0e2e873, us-east-1b subnet-8952dc13), one security group (usms-alb-sg).
Attributes set and read back: idle_timeout.timeout_seconds 60, routing.http.drop_invalid_header_fields.enabled true.

## Floci limitation: instant provisioning, and a DNS name that does not resolve
The waiter returned at once and the first poll read active. Real AWS spends two to four minutes in provisioning.
DNS name: usms-enrolment-alb-794a0732ca6d4a09.elb.floci. It does not resolve on the host (getent hosts returns nothing). Real AWS publishes <name>-<id>.<region>.elb.amazonaws.com, resolving to one public address per AZ node. Step 12 will show whether Floci serves the listener another way.

## Step 6: usms-enrolment-tg
target-type ip, HTTP:80, usms-vpc, health check GET / on traffic-port every 30s, timeout 5s, healthy 2, unhealthy 2, matcher 200. LoadBalancerArns 0 and describe-target-health [] until Steps 8 and 10.
A dead task keeps receiving requests for up to interval x unhealthy threshold = 30 x 2 = 60 seconds.

Your turn: modify-target-group --matcher HttpCode=200-399 read back 200-399; restored to 200 and read back 200. Same ARN throughout, so both changes applied in place with nothing recreated (labs/lab-05-ecs-alb/evidence/lab-05-matcher-yourturn.txt).
(a) A web application whose / answers 302 to a login page (or to /index.html) works perfectly but would be reported unhealthy forever by a strict 200 matcher.
(b) It would be a failure of my work, not a bug in the script: the script exists to check that the environment matches the design this lab specifies, and the design says matcher 200, so a script that reported 200-399 as passing would stop being able to detect drift, which is its whole purpose. If the design itself changed to 200-399, the right fix would be to change the design and the script together, deliberately.

## Step 7: how a task dies
deregistration_delay.timeout_seconds 30 (default 300) and load_balancing.algorithm.type least_outstanding_requests, both set and read back.
Order when ECS stops a task: deregister from usms-enrolment-tg -> draining, no new requests, in-flight requests get up to 30s -> deregistered -> SIGTERM -> stopTimeout (task definition) -> SIGKILL.

## Floci limitation: target group attributes list only what was set
describe-target-group-attributes returned exactly two attributes, the two I set. Real AWS returns the full list including defaults (stickiness.enabled false, slow_start.duration_seconds 0, and others), so on Floci an unset attribute cannot be confirmed by reading it back.

## Step 8: the listener
templates/lab-05-listener-default-actions.json written with an unquoted heredoc: valid JSON, zero literal $.
Listener HTTP:80 created (listener/app/usms-enrolment-alb/794a0732ca6d4a09/e36e179bfb864fdc - the load balancer's suffix is nested inside the listener ARN). Default action forward to usms-enrolment-tg; the target group now reports one attached load balancer.
Minor Floci difference: SslPolicy reads "" (empty string) where real AWS omits it, so the query shows null. Either way an HTTP listener has no TLS policy.

## Step 9: let the load balancer reach the tasks
policies/usms-enrolment-sg-ingress-alb.json (unquoted heredoc, valid JSON, zero literal $) admits tcp/80 from usms-alb-sg. Rule sgr-8db86d3a75cd980cd. Lab 04's rule from usms-app-sg is sgr-34325defd1d1ba040; both paths coexist until Step 13.

## Floci limitation: group-sourced rules still not readable, and not merged
The lab's verify query should show one port-80 permission with two Sources. Floci returns two separate port-80 IpPermissions, each with UserIdGroupPairs [] and IpRanges [], and describe-security-group-rules has no ReferencedGroupInfo. Real AWS merges both sources into one IpPermission and names each group.
Proven instead (labs/lab-05-ecs-alb/evidence/lab-05-step9-wiring.txt): 2 inbound tcp/80 rules, 0 with a CIDR source; the Lab 04 rule file names sg-96722a74c4be5da9e, which usms-web-01 carries; the Lab 05 rule file names sg-54033edc16ebffd09, which usms-enrolment-alb carries.
Consequence for Step 13: the old rule cannot be identified from the API by its source group, so it is revoked from the Lab 04 rule file (or by its rule ID) and the check afterwards is "1 inbound rule, 0 CIDR".

## Step 10: attach the service - FALLBACK TAKEN (service recreated)
templates/lab-05-service-load-balancers.json: valid JSON, zero $, containerName enrolment-api, containerPort 80.
update-service --load-balancers ... --health-check-grace-period-seconds 60 exited 0 but stored nothing: the response and a fresh describe-services both showed loadBalancers null and healthCheckGracePeriodSeconds null (labs/lab-05-ecs-alb/evidence/lab-05-step10-update-raw.json). The lab's own query also failed with "length() ... received null" because Floci returns no deployments list (Lab 04 limitation 8).
Floci limitation: update-service silently ignores --load-balancers and --health-check-grace-period-seconds. Real AWS either applies them (rolling controller) or rejects them with InvalidParameterException; it never reports success and drops them.
Because a silent no-op has the same effect as a rejection, I took the lab's documented fallback, with this danger notice:
- What was deleted: the ECS service usms-enrolment-svc and its two tasks. Task definition, cluster, roles, security group and log group untouched.
- What depends on it: Lab 06's scalable target names the service; it was recreated with the same name, cluster, task definition (usms-enrolment:2), desired count (2), subnets, security group, assignPublicIp DISABLED and the same four tags (Lab=04 kept; tags saved first to labs/lab-05-ecs-alb/evidence/lab-05-pre-recreate-tags.json).
- Reversible: the object is not recoverable, but an identical one was recreated in the same command block.
- Effect on later labs: none; the ARN is unchanged (service/usms-ecs-cluster/usms-enrolment-svc).
Sequence (labs/lab-05-ecs-alb/evidence/lab-05-step10-recreate.txt): desired 0, running 2 -> 0 by the second check, delete-service --force -> INACTIVE, create-service with --load-balancers. Lab 04's templates/lab-04-deployment-config.json does not exist in my repo (my Lab 04 service had deploymentConfiguration null), so that flag was omitted, matching the original.
After recreating: loadBalancers has the one entry (usms-enrolment-tg, enrolment-api, 80); healthCheckGracePeriodSeconds is still null.
Floci limitation: healthCheckGracePeriodSeconds is not stored on create-service either. Real AWS stores 60 and ignores target health for each task's first 60 seconds.

## Step 11: targets registered by the service
Without any register-targets call, the target group filled itself within the first poll: two targets, both initial (Elb.InitialHealthChecking / Elb.RegistrationInProgress), then 172.20.0.3 healthy by poll 2 and 172.20.0.4 healthy by poll 5, about 40 to 50 seconds (labs/lab-05-ecs-alb/evidence/lab-05-step11-targets.txt). Floci runs real health checks: path A confirmed for target health.
Floci limitations:
- Target.Id is the container's Docker bridge address (172.20.0.x), not an ENI address in 10.0.3.0/24 and 10.0.4.0/24, and Target.AvailabilityZone is None. Real AWS registers each task's ENI private IP, one per AZ. The one-address-per-private-subnet evidence the checklist asks for cannot be produced; the mapping is shown through Docker instead.
- describe-tasks returns no ENI attachment (IP None) and healthStatus None. Mapped through docker inspect: task eb3b766e... = 172.20.0.4, task 2897a016... = 172.20.0.3, both RUNNING (labs/lab-05-ecs-alb/evidence/lab-05-step11-health.txt).
- describe-services events None and deployments null, as in Lab 04.

ECS health vs target health:
| ECS healthStatus | Target health | Diagnosis |
|---|---|---|
| HEALTHY | healthy | Working |
| HEALTHY | unhealthy | The network path is broken: security group, subnet, or the health check path returning the wrong code |
| UNHEALTHY | unhealthy | The application is broken. Read the container logs |
| UNKNOWN | healthy | Not a fault. The task definition has no container health check |
| anything | unused | Nothing forwards to this target group |
Observed: ECS None (real AWS: UNKNOWN, because usms-enrolment:2 has no container healthCheck - jq shows null) and target healthy, so the "UNKNOWN / healthy - not a fault" row.

Your turn (labs/lab-05-ecs-alb/evidence/lab-05-step11-yourturn.txt): desired 2 -> 3: on the second poll (about 10s) running 3 and three healthy targets (172.20.0.5 added). Desired 3 -> 2: on the second poll running 2 and two targets; 172.20.0.4 was removed and 172.20.0.3 and .5 kept. I made no register-targets or deregister-targets call.
Floci limitation: the removed target never appeared as draining. Within one poll the count read 3 but the listing already showed 2, so deregistration was effectively immediate; real AWS would list it as draining for up to the 30-second deregistration delay. Also no AZ balancing is observable because Target.AvailabilityZone is None.
If the service did not register its own targets, after every single scaling event I would have had to register each new task's IP address in usms-enrolment-tg by hand (and deregister each stopped one), which is impossible to keep up with once Lab 06 scales automatically.

## Step 12: which proof I got
Data path from the host: NOT available. The DNS name usms-enrolment-alb-794a0732ca6d4a09.elb.floci does not resolve and curl returned http_code=000 (labs/lab-05-ecs-alb/evidence/lab-05-dataPath.txt). Only port 4566 is published, as the lab requires; I published no extra ports.
A trap I caught: curl to localhost:4566 with the ALB name in the Host header returned 200, but the body was S3's ListAllMyBucketsResult, and a made-up host name returned 200 too. Floci's 4566 answers any GET / as S3 ListBuckets. That 200 is not a load balancer response and I do not count it.
Data path inside Floci's network: AVAILABLE. Floci listens on port 80 inside its container (172.20.0.2 on floci-course_default). A throwaway curl container on that network requested http://172.20.0.2:80/ with the ALB host name and user agent lab05-step12-probe and got 200, Server: nginx. The request appears in the access log of task 172.20.0.5, with source 172.20.0.2 - so the request went listener -> target group -> a registered task, and back.
So: the listener, the forward action and target registration are real on this build; only the public DNS name and the published port are missing.
Control-plane proof (labs/lab-05-ecs-alb/evidence/lab-05-path-proof.txt): block 1 HTTP 80 forward -> usms-enrolment-tg; block 2 ip, HTTP 80, /, usms-vpc; block 3 172.20.0.3 and 172.20.0.5 reported "NOT in a Lab 02 private subnet" because Floci registers Docker bridge addresses (no task ENI); block 4 usms-enrolment-svc -> usms-enrolment-tg, enrolment-api, 80, grace None; block 5 empty because UserIdGroupPairs is not returned - wiring proven from the rule files instead.
Floci limitations:
- Security groups are not enforced (Lab 04 limitation 12): the request would have reached the task with or without the Step 9 rule, so this test proves forwarding, not the firewall.
- The task log's X-Forwarded-For field is "-". A real ALB adds X-Forwarded-For with the client address, because it terminates the connection and the target otherwise sees only the load balancer's address.
- Health checks are real: every task's nginx log shows GET / from 172.20.0.2 every 30 seconds (16:52:20, 16:52:50) with user agent Java/25.0.3, which is Floci's own health checker. Real AWS uses the user agent ELB-HealthChecker/2.0. The interval matches the target group's 30 seconds.
- My three test requests were spread across both tasks, so the listener forwards to more than one target.

## Step 13: the cutover - done, but Floci made it harder than the lab text
Danger notice (read before revoking): deleted = one inbound rule on usms-enrolment-sg, tcp/80 from usms-app-sg (Lab 04). Depends on it = nothing, because Step 12 proved the load-balanced path first. Reversible = yes, policies/usms-enrolment-sg-ingress.json puts it back. Effect = Lab 04's script was expected to flip one check.
What happened (labs/lab-05-ecs-alb/evidence/lab-05-step13-cutover.txt, labs/lab-05-ecs-alb/evidence/lab-05-step13-revoke-test.txt):
1. The lab's query finds the old rule by ReferencedGroupInfo.GroupId; Floci returns that as null, so it gave None. I identified the rule by elimination: two inbound tcp/80 rules, one is Step 9's sgr-8db86d3a75cd980cd, so the Lab 04 rule is sgr-34325defd1d1ba040.
2. revoke-security-group-ingress --security-group-rule-ids sgr-34325defd1d1ba040 returned True and removed nothing.
3. Revoking with the Lab 04 rule file (--ip-permissions file://policies/usms-enrolment-sg-ingress.json) returned true and emptied IpPermissions in describe-security-groups - it removed BOTH tcp/80 rules, including the load balancer's.
4. I reproduced both behaviours on throwaway groups (created and deleted): revoke by rule ID never changes anything, for CIDR or group rules; revoke by permission removes every tcp/80 group-sourced permission, because Floci stores the pairs without their GroupId and so cannot tell them apart.
5. I re-authorized only the Step 9 rule from policies/usms-enrolment-sg-ingress-alb.json (new ID sgr-f845a2aee2f620c21).
Final state: describe-security-groups shows 1 inbound permission, written from the usms-alb-sg file; 0 CIDR rules; the request through the listener still returns 200. describe-security-group-rules still lists 3 inbound rules, because Floci's revoke never updates that view.
Floci limitations:
- revoke-security-group-ingress by rule ID is a no-op that reports success. Real AWS removes exactly that rule.
- revoke by permission removes all same-port group-sourced permissions, not just the one named. Real AWS removes only the permission matching that source group.
- describe-security-group-rules and describe-security-groups disagree after a revoke. Real AWS shows the same rules in both.
- Security groups are not enforced, so none of this changed what can actually connect.
On real AWS the lab's two commands (find by ReferencedGroupInfo, revoke by ID) remove exactly the one rule.

Lab 04's script did NOT flip (labs/lab-05-ecs-alb/evidence/lab-05-pre-verify-04.txt vs labs/lab-05-ecs-alb/evidence/lab-05-post-verify-04.txt): PASS=38 FAIL=1 before and after, no difference. The lab expects 49/0 -> 48/1. The reason is my Lab 04 workaround: because Floci cannot read a group source back, the Lab 04 check reads the rule FILE (which still names usms-app-sg) and counts CIDR rules (still 0), and the API read-back was already a [floci] FAIL. So the script is blind to the cutover - a verification check that cannot detect the change it exists to detect. Exercise 2 is where this gets fixed. The service recreate at Step 10 also left every Lab 04 check unchanged.
The three responses: leave it and document the expected failure (right now - Lab 04's script records what Lab 04 built); update the check to assert the new source (Exercise 2, and on a real system in the same commit as the change); delete the check (almost never - the property still matters, only the expected value changed).

## Step 14: deploy behind the load balancer - draining NOT observable on Floci
pre-deploy (labs/lab-05-ecs-alb/evidence/lab-05-pre-deploy.txt): usms-enrolment:2, desired 2, running 2, targets 172.20.0.3 172.20.0.5, tasks 2897a016 4c5a2a78.
update-service --force-new-deployment returned TaskDef usms-enrolment:2, deployments null. 12 polls over 80 seconds (labs/lab-05-ecs-alb/evidence/lab-05-step14-poll.txt): running 2, both targets healthy, nothing changed. post-deploy: identical addresses AND identical task IDs. The lab's poll loop also cannot run as written, because it stops on length(deployments), which errors on null.
Floci limitation (same as Lab 04 Exercise 2): --force-new-deployment replaces no tasks. Real ECS starts new tasks, waits for them to pass the health check, deregisters the old ones, lets them drain for up to 30 seconds, then stops them.

Extra observation, not in the lab (labs/lab-05-ecs-alb/evidence/lab-05-step14-stoptask.txt): I stopped one task (4c5a2a78, 172.20.0.5) with ecs stop-task and polled every second.
- t+1s: its target was already gone - never shown as draining.
- t+3s: replacement 172.20.0.4 registered as initial, by the service.
- t+23s: 172.20.0.4 healthy (two checks passed). New task ID 0cef149b.
So the service replaces and registers a task and the health check gates it (initial -> healthy), but deregistration is instant: the deregistration delay (30s) is stored and never applied. No frame with draining next to healthy can be produced on this build.
Conceptually, on real AWS: the stopped task's target would sit in draining for up to 30 seconds, receiving no new requests while in-flight ones finish, and only then would ECS send SIGTERM and, after stopTimeout, SIGKILL.

## Step 15: listener rule - proven with real requests
templates/lab-05-rule-conditions.json (path-pattern /alb-health, /alb-health/*) and templates/lab-05-rule-actions.json (fixed-response 200 text/plain "usms-enrolment-alb ok"), quoted heredocs, both valid. Rule ARN nests the load balancer, listener and rule IDs: listener-rule/app/usms-enrolment-alb/794a0732ca6d4a09/e36e179bfb864fdc/006520a7bd0046ac.
describe-rules: priority 10, IsDefault false, path-pattern, fixed-response 200, no target group; then priority "default", IsDefault true, forward to usms-enrolment-tg.
Minor Floci difference: Conditions[0].Values is [] and the paths appear only under PathPatternConfig.Values, so the lab's query shows an empty Values list.
Requests through the listener, inside Floci's network (labs/lab-05-ecs-alb/evidence/lab-05-step15-rule-test.txt):
- /                          200, 896 bytes, Server nginx  -> default action, reached a task
- /alb-health                200, 22 bytes, no Server header, body "usms-enrolment-alb ok" -> the rule fired
- /alb-health/x              200, 22 bytes -> second pattern fired
- /alb-healthcheck-internal  404 from nginx -> fell through to the default action; this is why the rule uses two patterns rather than /alb-health*
The task access logs show / and /alb-healthcheck-internal but never /alb-health, so the fixed response was answered by the load balancer without contacting any target.

## Step 16: persistence across a restart - PERSISTENCE PROVEN
floci-down.sh (docker compose stop, state kept) -> enrolment containers 0 while stopped -> floci-up.sh. Every ARN re-derived from the API (by --names, by walking listener from load balancer, by tag for usms-alb-sg); all four match the originals. The lab's seven facts diffed with no difference (labs/lab-05-ecs-alb/evidence/lab-05-pre-restart.txt vs labs/lab-05-ecs-alb/evidence/lab-05-post-restart.txt). Extra facts also unchanged: deregistration delay 30, least_outstanding_requests, the rule's two paths, usms-enrolment-sg 1 inbound permission, usms-alb-sg 2 (80 and 443).
Honest caveats on the PERSISTENCE PROVEN line:
- The grace period reads None before and after; "unchanged" here means still not stored (Step 10 limitation), not 60 persisted.
- The enrolment-sg fact is length(IpPermissions[0].UserIdGroupPairs) = 0 on both sides, because Floci never returns the pairs; it cannot distinguish "the cutover persisted" from "no source at all". The extra count of 1 permission is the better evidence.
Runtime after restart (not configuration; labs/lab-05-ecs-alb/evidence/lab-05-step16-runtime.txt): the service started two NEW tasks (15192458, 034c5d83 - different IDs), which reused 172.20.0.3 and 172.20.0.4. 172.20.0.3 was healthy at once; 172.20.0.4 read unhealthy (Target.FailedHealthChecks) for about 20 seconds and then healthy. Floci health-checked it before the container was serving; this is exactly the case healthCheckGracePeriodSeconds exists for - on real AWS with a 60s grace period ECS would ignore that early failure rather than replace the task. Requests through the listener (/ -> 200 nginx, /alb-health -> 200 fixed response) worked again after the restart.

## Step 17: close the loop and audit (labs/lab-05-ecs-alb/evidence/lab-05-step17-loop.txt)
Run exactly as written first:
- Block 1: usms-alb-sg admits tcp/80 and tcp/443 from 0.0.0.0/0, no group sources.
- Block 2: source group None -> MISMATCH. False result: the check reads IpPermissions[0].UserIdGroupPairs[0], which Floci never returns.
- Block 3: printed nothing, then NOTE: carried by None. Cause found: the Step 16 restart had left all four Lab 3 instances (usms-web-01, usms-web-02, usms-db-01, usms-db-02) stopped, so the running filter matched nothing.
- Block 4: usms-alb-sg is the only security group tagged Lab=05; elbv2 describe-tags (supported) shows Lab=05 on both the load balancer and the target group, so no add-tags was needed.
Floci limitation: restarting Floci stops every EC2 instance, and they stay stopped; the ECS service restarts its own tasks, EC2 instances do not come back. On real AWS there is no equivalent - the control plane does not restart under you. I restored the pre-restart state with ec2 start-instances on the four instances; usms-web-01 kept its Elastic IP 54.205.147.173. Afterwards verify-lab-02 33/0, verify-lab-03 32/5 and verify-lab-04 38/1, all unchanged.
Block 3 re-run: the instance.group-id filter is ignored (it returned all four running instances, including the two db instances that carry usms-db-sg - Lab 04 Exercise 5 limitation), and [0] picked usms-web-02, so the lab's test printed NOTE. Client-side check on each instance's own security groups: usms-app-sg is carried by usms-web-01 and usms-web-02 only -> LOOP CLOSED (client-side): usms-web-01 is running, carries usms-app-sg, and now calls the load balancer's name instead of a task address. usms-app-sg no longer grants anything on the tasks; a security group is a name other rules refer to, not a property of the instance.
Block 2 stand-in -> CUTOVER CONFIRMED (by stand-in): usms-enrolment-sg has 1 inbound permission (2 before Step 13), 0 CIDR rules, and that permission was written from policies/usms-enrolment-sg-ingress-alb.json, which names sg-54033edc16ebffd09, the group the load balancer carries.

## Step 18: configs/lab-05.env
15 exports, every value looked up from the API. 14 populated; USMS_SVC_GRACE_PERIOD=None, because Floci never stores healthCheckGracePeriodSeconds (Step 10). It is left as the read-back value with a comment, rather than hard-coding 60, so the file stays a record of what exists. The checklist's "no empty values or None" cannot be met on this build for that one key.

## Section 8: verify-lab-05.sh and lab-05-cleanup.sh
Run exactly as the lab gives it: PASS=44 FAIL=5 (49 checks). Failures: enrolment-sg source from usms-alb-sg (UserIdGroupPairs not returned), grace period None, deployments null, lab-05.env contains None (the grace period), and "no secret is tracked by git" (the outputs/.gitkeep false positive, same as Labs 2 and 4).
A silent problem the run did not show: "cutover done: usms-enrolment-sg no longer admits usms-app-sg" passed, but on Floci the source list is always empty, so that check cannot fail - it would pass even with Step 13 skipped.
Adapted (same approach as Lab 04), every lab check kept:
- The three Floci checks are labelled [floci]: enrolment source readable via the API, grace period set, exactly one deployment.
- Stand-ins that can fail: the enrolment rule file names the group the load balancer carries; usms-enrolment-sg has exactly ONE inbound permission (it had two after Step 9, so this detects a skipped cutover); no CIDR-sourced ingress; runningCount = desiredCount with pendingCount 0; healthy targets = desiredCount.
- lab-05.env: "no empty values" kept; None allowed only for the documented USMS_SVC_GRACE_PERIOD.
- Git hygiene: ignores outputs/.gitkeep, as in Labs 2 and 4.
Result: PASS=52 FAIL=3, the three [floci] checks (labs/lab-05-ecs-alb/evidence/lab-05-verify.txt).
Cleanup script: copied from the lab, passes bash -n, NOT run. Fixed a typo in the lab text, which said "run AFTER lab-04-cleanup.sh and BEFORE lab-04-cleanup.sh"; the lab's own order is Lab 06 cleanup first, then this, then Lab 04. Its scalable-target guard treats an unsupported Application Auto Scaling as 0 targets, so on this build it does not block.

## Review questions

**1. Group-sourced rules and load balancers: what they have in common.**
Lab 04 sourced the enrolment rule from a security group because the tasks have no stable addresses, and this lab put a load balancer in front of them for the same underlying reason: the things being connected change identity faster than anyone can write their addresses down. Both replace an address with a name that stays fixed while the members behind it change - a group ID that any instance can carry, and a DNS name and target group that ECS fills and empties. The general problem is indirection for a changing set of endpoints: refer to a stable name and let something else maintain the mapping to whatever currently exists. A third example elsewhere in computing is DNS itself, or service discovery such as Kubernetes Services or AWS Cloud Map, where clients call a name and a registry tracks which addresses currently answer for it.

**2. "The load balancer says unhealthy, so the application is broken" - why is that unsound?**
The target group's health check only knows that a request from the load balancer to that address did not return the expected code in time. It cannot tell "the application is broken" from "the application is fine but the network path is broken" - a security group that does not admit usms-alb-sg, a wrong port, or a health check path that answers 302 under a strict 200 matcher all look identical to a crashed process. ECS's own healthStatus (from a container health check run inside the task) is the field that separates them: HEALTHY in ECS with unhealthy at the load balancer means the path, not the application. My diagnostic order: read TargetHealth.Reason and Description; compare with ECS healthStatus for the same task; check the tasks' security group admits the load balancer's group; check the health check path, port and matcher against what the application actually returns; only then read the container logs. On this build the container health check was absent (UNKNOWN on real AWS, None on Floci) and the targets were healthy, which is the "not a fault" row.

**3. There is no update-target-group-target-type.**
A target group's type is part of its identity, not its configuration: an ip target group and an instance target group hold different kinds of things, so changing one into the other would be creating a different object, and AWS makes you do exactly that. The health check settings, matcher and attributes are configuration - modify-target-group changed the matcher in place at Step 6 and the ARN stayed the same. Lab 04's task definition revisions are the same idea from the other direction: a revision is immutable, so a change creates :2 rather than editing :1. Two more fields in this lab that are identity: the load balancer's scheme (internet-facing cannot become internal) and its type (application cannot become network); the target group's VPC is another. One that looks like it should be fixed but is not: the load balancer's security groups, which set-security-groups changes in place (and its subnets, via set-subnets).

**4. A request arrives as ECS decides to stop the task that would serve it.**
Timers, in the order they apply: ECS deregisters the task from the target group; the load balancer stops sending it new requests and puts it in draining for up to deregistration_delay.timeout_seconds (30 s, on the target group, Step 7); when draining ends ECS sends SIGTERM and waits up to stopTimeout (the task definition, Lab 04) before SIGKILL; and minimumHealthyPercent / maximumPercent (the service) decide whether a replacement starts first. The healthCheckGracePeriodSeconds (60 s, on the service) applies to the replacement, not the leaving task. Whether the request succeeds depends on which side of deregistration it falls: if the load balancer chose the target before deregistration, the request is in flight and has up to 30 s to finish, which a millisecond API easily does, so it succeeds; if it arrives after, the load balancer simply sends it to another healthy target, so it also succeeds. With the delay left at 300, requests would still succeed, but every task stop would take five minutes, so deployments and scale-in would be slow and pay for capacity that is doing nothing. On Floci, deregistration was instant (Steps 11 and 14), so this sequence could not be observed.

**5. Step 13 made Lab 04's verification script fail (or should have).**
For updating it immediately: the architecture changed deliberately, so a check that encodes the old design now produces a known-false failure, and a team that learns to ignore one red line stops noticing the next. For leaving it failing and documented: Lab 04's script is the record of what Lab 04 built, and rewriting it the moment it disagrees with reality is how real regressions get silenced. With four other engineers I would update it in the same change as the cutover, asserting the property (only a named group, now usms-alb-sg) with the reason in the commit message, because otherwise each of them has to rediscover why it is red. One engineer might reasonably change the answer if the change were experimental or might be rolled back, where leaving the old assertion failing is the honest signal that the system is not in its intended state. In my case the script did not fail at all, because my Lab 04 workaround read the rule file instead of the environment - a stronger argument for writing checks against the property than any I expected to make.

**6. Internet-facing load balancer, private tasks: how both are true.**
The load balancer's nodes sit in usms-public-subnet-a and usms-public-subnet-b, whose route table usms-public-rt sends 0.0.0.0/0 to usms-igw, so the nodes get public addresses that the internet can reach on the listener's port, admitted by usms-alb-sg. The tasks sit in usms-private-subnet-a and -b, whose route table usms-private-rt has no internet gateway route (only usms-nat for outbound image pulls and the S3 endpoint), and they have no public address, so nothing on the internet can open a connection to them; the load balancer terminates the client's connection and opens a new one to the task's private address inside usms-vpc, admitted by usms-enrolment-sg because the source is usms-alb-sg. An attacker who could change the load balancer's configuration could add rules or listeners and point them at any target group in the VPC, reach anything that admits usms-alb-sg, and see or redirect all traffic to the API - but still could not reach the tasks on any port other than what usms-enrolment-sg allows. Had the tasks had public addresses, anyone could bypass the load balancer, its rules and any future TLS or WAF entirely, and the only protection would be a single security group rule on each task.

**7. Requests per target versus CPU as a scaling signal.**
For a web API the thing that runs out first is usually concurrency - connections, threads, database calls waiting on I/O - and that shows up as requests per task long before CPU moves; requests per target also measures demand directly, so it scales on the cause rather than a symptom, and it reacts to demand that CPU never sees while requests queue. CPU is the better signal when the work is compute-bound, such as report generation, image processing or encryption, where each request's cost varies widely and CPU is the actual limit. ALBRequestCountPerTarget would scale the enrolment application badly if requests were very unequal in cost (one "submit enrolment" doing far more work than many "list modules" calls), if most load did not arrive through the load balancer at all (background jobs or queue consumers), or if a single slow dependency such as the database were the bottleneck, where adding tasks adds more requests to the thing that is already saturated.
