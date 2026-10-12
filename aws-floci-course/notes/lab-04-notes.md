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
