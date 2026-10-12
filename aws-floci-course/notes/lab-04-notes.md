# Lab 04 notes

## Support path: B (ECS only)
Probed on Floci 2026-10-12.
- ECS: supported. describe-services on a missing cluster returns ClusterNotFoundException, which is a real API answer.
- Application Auto Scaling: NOT implemented. describe-scalable-targets returns UnknownOperationException (AnyScaleFrontendService.DescribeScalableTargets).
- CloudWatch (put-metric-data, describe-alarms) and CloudWatch Logs: supported.
- Effect: nothing in Lab 04 changes. Lab 06 needs its documented fallback.

## Floci limitation: Container Insights setting not returned
create-cluster accepted --settings name=containerInsights,value=enabled, but describe-clusters --include SETTINGS returns Settings: null.
Real AWS would publish per-service CPU and memory to the AWS/ECS namespace. Lab 06 cannot rely on that metric here and needs a custom metric.

## Same policy, two kinds of compute
Lab 03: usms-web-01 -> instance profile -> usms-ec2-app-role -> USMSStudentDataReadWrite
Lab 04: ECS task    -> taskRoleArn      -> usms-ecs-task-role -> USMSStudentDataReadWrite
Neither holds a key on disk. Both start working when Lab 10 creates the bucket usms-student-data.
Floci limitation: containers cannot fetch their task-role credentials here. The association (task definition names the role, role trusts ecs-tasks, role holds the policy) is verifiable through describe-task-definition and iam get-role.

## Floci limitation: iam list-entities-for-policy unsupported
Returns UnsupportedOperation. The reverse lookup (which roles hold the policy) was done by asking each role with list-attached-role-policies instead.

## Floci limitation: task definition logConfiguration not stored
register-task-definition accepted the awslogs logConfiguration, but describe-task-definition returns logConfiguration: null for the container. The registered file (templates/lab-04-taskdef.json) is the evidence of what was sent.
Real AWS would store it and send task stdout/stderr to /usms/ecs/enrolment. Here no task logs would reach the log group.

## Floci limitation: task definition logConfiguration not stored
register-task-definition accepted the awslogs logConfiguration, but describe-task-definition returns logConfiguration: null for the container. The registered file (templates/lab-04-taskdef.json) is the evidence of what was sent.
Real AWS would store it and send task stdout/stderr to /usms/ecs/enrolment. Here no task logs would reach the log group.

## Floci limitations: service read-back
- describe-services returns taskDefinition as the family name (usms-enrolment), not the full ARN with :1.
- describe-services events list is None; Floci does not narrate service events, so stoppedReason and event messages cannot be used for diagnosis here.
- Tasks do run as real Docker containers (floci-floci-course-ecs-<id>-enrolment-api).

## Verification result
verify-lab-04.sh: PASS=38 FAIL=1. The single failure is labelled [floci]: describe-security-groups returns UserIdGroupPairs as null for usms-enrolment-sg, so the group source cannot be read back through the API. The same wiring is proven by the rule file (policies/usms-enrolment-sg-ingress.json) naming usms-app-sg, which web-01 carries, and by zero CIDR-sourced rules.

## Review questions

### Q1. "I put auto scaling on the task definition."

That is wrong in three ways. Auto scaling is not attached to the task definition at all: in Lab 06 it is attached to the **service**, through a scalable target whose resource ID has the shape `service/usms-ecs-cluster/usms-enrolment-svc` (the shape I saw in the service ARN in Step 10). What it modifies is the service's `desiredCount` and nothing else. And the task definition cannot be the target because it is an immutable, versioned blueprint with no count field in it: changing it means registering a new revision, which is what I did in Exercise 2. The ECS object that makes reality match is the **service**, which keeps `runningCount` equal to `desiredCount`. The observable consequence of ECS knowing nothing about the scalable target is that `describe-services` shows no scaling policy or target, so a count that changes through a policy and one I changed by hand with `update-service` (2 to 3 to 2 in Step 11) look exactly the same to ECS. The record of why it moved lives in Application Auto Scaling's scaling activities, not in ECS.

### Q2. One policy, two delivery mechanisms

Lab 1 wrote `USMSStudentDataReadWrite` for a bucket that did not exist. In Lab 3 an instance profile delivered it to `usms-web-01`: the instance profile wraps `usms-ec2-app-role`, and the instance's metadata service hands the code temporary credentials for that role. In this lab the task role does the same job for a container: the task definition names `usms-ecs-task-role`, and the container is given temporary credentials for that role through a credentials endpoint that the SDK finds on its own. Neither needs a key on disk because both are short-lived credentials from the Security Token Service, issued for a role the compute is trusted to assume (`ec2.amazonaws.com` in one case, `ecs-tasks.amazonaws.com` in the other) and rotated automatically, so there is nothing for me to store, leak or commit. Both chains are already complete today: I checked that both roles list the same policy and that the document names `arn:aws:s3:::usms-student-data`. The moment a later lab creates that bucket, both begin to work at once with no change to either role, because the policy already points at the right ARN. On Floci the association is observable but the credentials are not delivered to containers, so I verified the wiring through the task definition and the role and did not call S3 from a task.

### Q3. Telling the two roles apart

If the **execution role** is wrong, the task never starts and its stopped reason mentions the image pull or the log stream, because ECS itself needs that role before my code exists. If the **task role** is wrong, the task starts and runs and then my code gets `AccessDenied` when it calls S3. Both share an identical trust policy because the trust policy says only *who may assume* the role, and in both cases the answer is the same: the ECS tasks service principal, `ecs-tasks.amazonaws.com`. The difference between the roles is in their permissions, and in who uses the credentials (ECS before the container starts, versus the application inside it), not in who is allowed to assume them.

### Q4. Why the enrolment rule names a group and not a CIDR

Even if the task count never changed, the source side is the web tier, and a CIDR such as `10.0.1.0/24` admits every address in that subnet: the NAT gateway, any future instance, anything. A group reference says what I mean, which is "only members of `usms-app-sg`", and it follows those members whatever their addresses are. It also matters because addresses are not stable: every ECS task gets its own network interface and a fresh private address, and replacement tasks get different ones. Once Lab 06 lets the number of tasks change automatically, an address-based rule would have to be kept in step with a moving set, whereas the group reference needs no maintenance. That is close to mandatory, not just tidier. I checked this one: the rule file names `usms-app-sg`, web-01 carries that group, and the group has zero CIDR-sourced rules.

### Q5. What Fargate removes and what it does not

Fargate removes the instances: no host to size, patch or pick an AMI for, no instance profile for the host, no SSH, and billing per task rather than per instance. It does not remove the network or the identity model. An `awsvpc` task still gets its own network interface in my subnet, carries my security group (`usms-enrolment-sg`) and follows Lab 2's route tables: the private route table, the NAT gateway for the image pull and the S3 endpoint. It still takes an address out of the subnet's pool (a /24 gives 251 usable, since AWS reserves five). It still needs two IAM roles, a log destination and a valid CPU and memory pair (256 and 512 here). What I stopped managing is the machine; what I still manage is everything around it.

### Q6. Persistence in memory mode versus hybrid mode

Lab 1 showed that an unchanged account identity after a restart is not evidence of persistence, because the account ID is fixed by Floci. `aws sts get-caller-identity` (or `whoami.sh`) would look identical in memory and hybrid mode for that reason. A command that would differ is `aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc`: in memory mode the whole cluster would be gone after a restart (`ClusterNotFoundException`), while in hybrid mode the cluster and the service record come back with `desiredCount` 2. I did not restart Floci in this lab, so this answer is **conceptual** for Lab 4, backed by Lab 3's observation that after a restart the records persisted (subnets, security groups, tags) while runtime state did not (a stopped instance, a dead container). By the same logic I would expect the service's `desiredCount` to persist while `runningCount` may not match it until the tasks are running again.
