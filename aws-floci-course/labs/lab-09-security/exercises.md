# Lab 09 - Independent Lab Exercises

Environment: Floci v1.5.34 (support path A: IAM management and `simulate-principal-policy` both work), AWS CLI v2.31.35. Nothing is enforced on Floci: every control below is judged by reading it, and by the policy simulator where it applies.

Labels: **Observed** (seen in command output), **Conceptual** (reasoned, not run), **Floci limitation** (behaves differently from real AWS). Full output is in [`evidence/`](evidence/).

---

## Exercise 1 - Basic: finish egress on the web tier

`policies/usms-app-sg-egress.json` holds six rules, each with a Description. I used an **unquoted** heredoc, because four IDs (the S3 prefix list, `usms-alb-sg`, `usms-db-sg`) must be expanded from the env files when the file is written, and nothing else in the document contains a `$`. The written file was checked for zero `${UPPER}` leftovers and zero empty IDs. That check matters, because the same mistake hit me in Steps 13 and 16 (see the README).

| # | Requirement | Rule |
|---|---|---|
| 1 | S3 through the Lab 02 gateway endpoint | tcp/443 → prefix list `pl-63a5400a` |
| 2 | AWS service endpoints over HTTPS, STS included | tcp/443 → 0.0.0.0/0 |
| 3 | The enrolment API through the load balancer | tcp/80 → **`usms-alb-sg`**. The web tier calls the ALB (Lab 05), never the tasks, so the reference is to the load balancer's group, not `usms-enrolment-sg` |
| 4 | PostgreSQL on the data tier | tcp/5432 → `usms-db-sg` |
| 5a | DNS | udp/53 → `10.0.0.2/32` |
| 5b | DNS over TCP | tcp/53 → `10.0.0.2/32` |

**Why 10.0.0.2:** AWS reserves the first four addresses and the last address of every subnet. The VPC's base address plus two (`10.0.0.0/16` → `10.0.0.2`) is the Amazon-provided resolver (Lab 02). DNS uses UDP first and falls back to TCP for truncated or large answers, so both rules are needed.

**Authorise before revoke**, because security groups are allow-lists. Revoking the default first would leave the group with no egress for a moment, so every connection the web tier opens in that gap (to the database, to S3) would fail.

Observed ([evidence/lab-09-ex1.txt](evidence/lab-09-ex1.txt)):
- **The change:** six rule IDs were returned, the revoke returned `True`, and allow-all left = **0** (counted with the corrected `'-1'` query). Ingress is unchanged (80 and 443 from the internet, tcp/22 from the bastion group).
- **The SG audit:** app-sg no longer has the MED "default allow-all" finding, so the total went from MED=7 to MED=6. The matrix lists the written destinations. `verify-lab-09.sh` is unchanged at PASS=43 FAIL=7.
- **Floci limitation:** the prefix-list and group targets are stored blank, as in Steps 13–16. The UDP and TCP 53 rules, which are CIDRs, read back exactly.

**The bastion, in two sentences.** `usms-bastion-sg`'s egress differs in kind, because a jump host exists to *initiate* connections (SSH out to the hosts it administers), while every other tier only answers. Its destination should be tcp/22 to `usms-app-sg`, a group reference that follows the web tier, plus DNS to `10.0.0.2`, and nothing else.

**Why 169.254.169.254 needs no rule:** link-local traffic to the instance metadata service is answered by the hypervisor (the Nitro card) and never passes through a security group. That's why IMDS has its own controls (Step 11).

---

## Exercise 2 - Intermediate: a break-glass role, and the open findings

### Part A: `usms-breakglass-role`

([evidence/lab-09-ex2a.txt](evidence/lab-09-ex2a.txt))

| Requirement | Implementation |
|---|---|
| 1. Assumable only by usms-admin-01 | `Principal: {"AWS": "arn:aws:iam::000000000000:user/usms-admin-01"}` (`policies/trust-breakglass.json`) |
| 2. Requires MFA | `"Bool": {"aws:MultiFactorAuthPresent": "true"}` |
| 3. Requires an external ID | `"StringEquals": {"sts:ExternalId": "usms-breakglass-2026"}` |
| 4. The shortest maximum session | `--max-session-duration 3600`. I tried 3599 and IAM refused it: *"valid min value: 3600"* |
| 5. A permissions boundary | `USMSPermissionsBoundary`, applied with `put-role-permissions-boundary` (see the finding below) |
| 6. Only the calls Lab 06 used to suspend scaling | `USMSBreakGlassScaling`: `application-autoscaling:RegisterScalableTarget` (`--suspended-state`) and `DescribeScalableTargets` (the read-back). There are no wildcard actions |

**AND, not OR.** Both conditions are in **one Condition block**. IAM ANDs the condition keys of a block (only the values listed under one key are ORed), so the session needs MFA *and* the external ID. With two separate statements it would be OR: either condition alone would be enough.

**Observed with the simulator:**
- RegisterScalableTarget and DescribeScalableTargets are `allowed`.
- DeleteScalingPolicy, `ecs:UpdateService` and `iam:CreateUser` are denied. That's the ten-second policy.

**A finding about Floci's boundaries.** At first `iam:CreateUser` and `ec2:DeleteVpc` came back `implicitDeny`, not the boundary's `explicitDeny`. `create-role --permissions-boundary` **does not store the boundary** on this build. After `put-role-permissions-boundary`, the same simulations return **`explicitDeny`**. So on Floci only `put-role-permissions-boundary` stores a boundary, the simulator enforces it, and `get-role` never shows it.

### Part B: the open confused-deputy findings

([evidence/lab-09-ex2b.txt](evidence/lab-09-ex2b.txt), [evidence/lab-09-iam-findings-after.txt](evidence/lab-09-iam-findings-after.txt))

Each trust was replaced only after saving an undo document.

| Role | Decision | Why |
|---|---|---|
| `usms-ecs-exec-role` | **fixed**: `policies/trust-ecs-tasks-scoped.json` | ECS sends `aws:SourceAccount` and `aws:SourceArn`; the same document as the task role |
| `usms-lambda-exec-role` | **fixed**: `policies/trust-lambda-scoped.json` | Lambda sends both keys; `SourceArn` is `arn:aws:lambda:us-east-1:000000000000:function:*` |
| `usms-ec2-app-role` | **accepted** | EC2 sends no `aws:SourceArn` for an instance-profile role; a condition would deny `usms-web-01` its own credentials |
| `usms-eks-node-role` | **accepted** | EKS nodes are EC2 instances, with the same behaviour |
| `usms-eks-cluster-role` | **accepted** | I haven't verified which source keys EKS sends; a condition on a key that's never sent denies everything |

The two EKS roles are outside the lab's list of three; Lab 07 added them.

The acceptances live in the committed file **`configs/usms-iam-accepted-findings.json`**. Each entry has a role, the finding text, a reason, a compensating control, and who accepted it and when. `usms-iam-audit.sh` now loads that file (the path can be overridden with `USMS_IAM_ACCEPTED`). It prints each accepted finding as `ACCEPTED`, together with its reason, and leaves it out of the count.

Observed:
- **With the file:** `HIGH=0 MED=33 ACCEPTED=3 roles=10`, exit 0, down from HIGH=6 in Step 5.
- **Constraint test** (the same audit pointed at an empty file): `HIGH=3 ACCEPTED=0`, exit **1**. An unaccepted HIGH still fails the audit.

---

## Exercise 3 - Problem solving: the exposure report

`scripts/utilities/usms-exposure-report.sh` writes one line per network interface in `usms-vpc` and saves `outputs/lab-09-exposure.json`. The verdict comes from three things only:
- the subnet's route table (explicit association, else the main table);
- the interface's public address (from the ENI association, else an Elastic IP on its instance, else the instance's public address);
- the ingress rules of the groups it wears.

Names are printed for the reader but never used for a verdict.

Observed ([evidence/lab-09-ex3.txt](evidence/lab-09-ex3.txt)):

```
usms-web-02    172.20.0.3   -                NO PUBLIC ADDRESS   (igw route on rtb-79f00a19, but no public address; loopback 127.0.0.1 ignored)
usms-web-01    172.20.0.4   54.205.147.173   EXPOSED             (igw route + public address + sg allows 80,443 from 0.0.0.0/0)
usms-db-01     172.20.0.5   -                ISOLATED            (no igw route on rtb-e509a19b; loopback 127.0.0.1 ignored)
usms-db-02     172.20.0.6   -                ISOLATED            (no igw route on rtb-e509a19b; loopback 127.0.0.1 ignored)
EXPOSED=1  ISOLATED=2  NO PUBLIC ADDRESS=1  interfaces=4
```

The output from `~` and from `labs/lab-09-security/` was identical, and Exercise 1 didn't change it, because the verdicts read ingress, not egress.

**How each constraint is met:**
- **Runs from any directory:** configs are resolved from `BASH_SOURCE`.
- **No arguments and no hard-coded IDs:** the VPC comes from `configs/lab-02.env`.
- **A group not in the cache:** it's fetched individually, and reported as "not readable" if that fails.
- **An interface with no description, or no instance:** it falls back to the interface ID.
- **A subnet with no explicit association:** the main route table is used.
- **An interface left by a terminated instance:** the verdict is **ORPHANED**.
- **`set -uo pipefail` without `-e`:** the script's comment explains that a report must finish and say "unknown", not stop half-way.

**My verdict for a public interface with no ingress rule: ADDRESSED, NO OPEN PORT, not EXPOSED.** The internet can send packets to it, and the security group drops every one of them. That isn't exposed today, but one rule away from it, so it gets its own verdict rather than either extreme. This is the NAT gateway's case in the lab's example.

**Floci limitations:**
- **Only four interfaces exist**, one per Lab 3 instance. Floci models no ENIs for the ALB nodes, the NAT gateway or the Fargate tasks, so those rows from the lab's example cannot appear.
- **Every instance reports `127.0.0.1` as its public address.** It's loopback, not an internet address (`ipaddress.is_global` is false), so the script ignores it and says so. `usms-web-01`'s real public address is its Elastic IP, associated by instance.

---

## Exercise 4 - Challenge: a security review for the information security officer

*For: the university's information security officer.*

### 1. The second front door

`usms-web-01` is on the public internet in its own right. It sits in a public subnet with an internet-gateway route, it has the Elastic IP `54.205.147.173`, and `usms-app-sg` admits tcp/80 and tcp/443 from `0.0.0.0/0` (Exercise 3 calls it EXPOSED). Those rules date from Lab 02 Step 14, when the web server *was* the front door. Since Lab 05 the application's public entrance is `usms-enrolment-alb`, and nobody revisited the web tier's rules. The rules are a leftover, not a decision.

**It should not stay reachable.** An attacker who finds the Elastic IP bypasses the load balancer: its listener rules, its health checks, and the single place where a WAF or TLS policy would go. Moving the web tier behind the load balancer means:
- a target group (`usms-web-tg`, target type `instance`, health check on `/`);
- a listener rule on the existing ALB listener (by host or path);
- in `usms-app-sg`, adding tcp/80 from `usms-alb-sg` **before** revoking 80 and 443 from `0.0.0.0/0`;
- releasing the Elastic IP last.

What breaks: anything that uses the Elastic IP or the instance's own DNS name directly (bookmarks, a DNS record pointing at `54.205.147.173`, SSH by public IP), and the web tier's own HTTPS on 443 unless the ALB terminates TLS for it.

**The other side, in two sentences.** The web tier serves the static portal, which is meant to be public, so a direct path is simpler and one less hop. And the ALB is now a single point of failure for both applications, one bill and one misconfiguration away from taking both down.

### 2. What the egress control bought

Steps 13–15 gave `usms-enrolment-sg`, `usms-alb-sg` and `usms-db-sg` written egress; Exercise 1 did the same for `usms-app-sg`.

**Three attacker behaviours it now stops:**
1. **A compromised enrolment task opening an interactive shell back to the attacker** (a reverse shell on tcp/4444 or 22). Control: `usms-enrolment-sg` egress is tcp/443 only (Step 13).
2. **A compromised database host exfiltrating data over a non-HTTPS channel** (raw TCP, DNS tunnelling to an outside resolver, SMTP). Control: `usms-db-sg` egress is tcp/443 only (Step 15).
3. **A compromised load balancer path being used to reach anything except the enrolment tasks.** Control: `usms-alb-sg` egress is tcp/80 to `usms-enrolment-sg` only (Step 14).

**Two it does not stop:**
1. **Exfiltration over HTTPS to any host.** tcp/443 to `0.0.0.0/0` is still open for the image pull, the logs and OS updates. Closing it needs hostname filtering: AWS Network Firewall at about **$0.395 per endpoint-hour plus $0.065 per GB processed** (https://aws.amazon.com/network-firewall/pricing/), or interface endpoints at about **$0.01 per endpoint per AZ-hour plus $0.01 per GB** (https://aws.amazon.com/privatelink/pricing/).
2. **Misuse of a legitimate credential.** A task that reads transcripts with its own role and posts them over HTTPS uses only allowed paths. Egress rules control *where*, not *what*.

All of these prices are us-east-1 list prices from the pages cited, as I understand them; they should be confirmed on those pages before any budget decision.

*What you bought:* the attacker's choice of channel. Before, a compromised host could talk to anything on any port. Now it can only talk HTTPS, plus PostgreSQL and DNS from the web tier.

### 3. Who can read and who can write transcripts

| Principal | How it gets access | Read / write | Granting document |
|---|---|---|---|
| `usms-ec2-app-role` | instance profile on `usms-web-01` | read and **write and delete** | `USMSStudentDataReadWrite` |
| `usms-ecs-task-role` | every `usms-enrolment` task | read and **write and delete** | `USMSStudentDataReadWrite` |
| `usms-eks-node-role` | **every pod on every EKS node** (Lab 07) | read and **write and delete** | `USMSStudentDataReadWrite` |
| `usms-transcripts-reader-role` | a future reporting task | read only (explicit Deny on writes) | `USMSStudentDataReadOnly` |
| `usms-lambda-exec-role` | Lambda functions | read (`s3:GetObject`) | `USMSLambdaBasic` |
| `usms-audit-01`, `usms-intern-01` | group `usms-auditors` | **read** (real AWS: `ReadOnlyAccess` includes `s3:Get*` and `s3:List*`) | AWS-managed `ReadOnlyAccess` |
| account root | the account | everything | (always) |

**The auditors group is a real finding.** Two human accounts, one of them an intern, can read every student's transcript through an AWS-managed read-only policy, and no role-based inventory would ever show it. **Floci limitation:** Floci's copy of `ReadOnlyAccess` is a stub with `Allow "*"` on `"*"`, so here the simulator even reports `s3:PutObject` and `iam:CreateUser` as allowed for the auditors. On AWS the policy is read-only.

**How I know the list is complete, and its limits.**
- **On real AWS:** the authoritative answers come from `aws iam get-account-authorization-details` (every user, group, role and policy in one call) and **IAM Access Analyzer**. Access Analyzer finds every principal, inside or outside the account, that a resource policy lets in; external-access analysis is free (https://aws.amazon.com/iam/access-analyzer/pricing/).
- **Why the course can't run them:** neither is available on this build (Step 3), and nor is `list-entities-for-policy`.
- **What I did instead:** I listed every role, user and group, read every attached policy document, and kept any statement whose Resource names the bucket. That's how `USMSLambdaBasic` was found, in Exercise 5. I also simulated each user.

This finds identity grants, but it can't see a bucket policy, because the bucket doesn't exist yet. Exercise 5's draft closes that by allowing only the five roles.

### 4. Knowing when something changes

**What I'd put in place:**
- **AWS CloudTrail:** a trail for management events in every region. The first copy of management events is free (https://aws.amazon.com/cloudtrail/pricing/); S3 storage of the logs is the only cost.
- **AWS Config:** recording `AWS::EC2::SecurityGroup`, `AWS::IAM::Role` and `AWS::IAM::Policy`, with rules such as "restricted-ssh". About **$0.003 per configuration item recorded** and **$0.001 per rule evaluation** (https://aws.amazon.com/config/pricing/).
- **Amazon GuardDuty:** reads CloudTrail and VPC Flow Logs for unusual assume-role or credential use. 30-day free trial, then priced by event volume (https://aws.amazon.com/guardduty/pricing/).
- **CloudWatch alarms** on CloudTrail metric filters for `AuthorizeSecurityGroupIngress`, `AttachRolePolicy`, `UpdateAssumeRolePolicy` and `CreateAccessKey`, at **$0.10 per alarm per month** (https://aws.amazon.com/cloudwatch/pricing/).

**The free part:** CloudTrail management events and Access Analyzer's external-access findings.

**The morning after an incident, in this order:**
1. CloudTrail for the incident window, filtered on the identity that was compromised: what it called, from which IP.
2. Every IAM change in that window (`Create*`, `Attach*`, `Put*`, `UpdateAssumeRolePolicy`, `CreateAccessKey`), because a persistent attacker's first move is to make a way back in.
3. Every security group change.
4. GuardDuty findings.
5. S3 data events on the transcripts bucket, if they were enabled: these are what tell you whether transcripts were read.

Everything in Lab 09 is **preventive**. These are the **detective** half, and none of it exists on Floci (Section 11).

### The command sequence for moving the web tier behind the load balancer (written, NOT run)

```bash
# 1. a target group for the web tier
aws elbv2 create-target-group --name usms-web-tg --protocol HTTP --port 80 \
  --vpc-id "$USMS_VPC_ID" --target-type instance --health-check-path /
WEB_TG=$(aws elbv2 describe-target-groups --names usms-web-tg --query 'TargetGroups[0].TargetGroupArn' --output text)

# 2. register both web instances
aws elbv2 register-targets --target-group-arn "$WEB_TG" \
  --targets Id="$USMS_WEB_INSTANCE" Id="$USMS_WEB2_INSTANCE"

# 3. a listener rule that sends the portal to the web tier
aws elbv2 create-rule --listener-arn "$USMS_ALB_LISTENER_ARN" --priority 20 \
  --conditions Field=path-pattern,Values='/portal*' \
  --actions Type=forward,TargetGroupArn="$WEB_TG"

# 4. let the load balancer reach the web tier - BEFORE removing the internet
aws ec2 authorize-security-group-ingress --group-id "$USMS_APP_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":80,\"ToPort\":80,\"UserIdGroupPairs\":[{\"GroupId\":\"$USMS_ALB_SG\",\"Description\":\"HTTP from the load balancer only\"}]}]"
# ... and wait until the target group reports both targets healthy

# 5. DANGER - removes direct internet access to the web tier.
#    What breaks: every client using 54.205.147.173 or the instance DNS name directly.
#    Reversible: yes, re-authorise tcp/80 from 0.0.0.0/0 (Lab 02 Step 14).
#    Do this only after step 4's targets are healthy through the load balancer.
aws ec2 revoke-security-group-ingress --group-id "$USMS_APP_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0

# 6. DANGER - removes direct HTTPS to the web tier.
#    What breaks: any client using https:// to the instance; TLS must terminate on the ALB first.
#    Reversible: yes, re-authorise tcp/443 from 0.0.0.0/0.
#    Do this only once an HTTPS listener with a certificate exists on the ALB.
aws ec2 revoke-security-group-ingress --group-id "$USMS_APP_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0

# 7. DANGER - gives up the web tier's public address.
#    What breaks: any DNS record or bookmark pointing at 54.205.147.173; it cannot be got back once released.
#    Reversible: disassociate-address is; release-address is NOT.
#    Disassociate first, wait a week of quiet, then release.
aws ec2 disassociate-address --association-id "$(aws ec2 describe-addresses --allocation-ids "$USMS_WEB_EIP_ALLOC" --query 'Addresses[0].AssociationId' --output text)"
```

---

## Exercise 5 - Integration: the bucket policy the S3 configuration lab will apply

`scripts/utilities/usms-bucket-policy-draft.sh` ([evidence/lab-09-ex5.txt](evidence/lab-09-ex5.txt)):

- **The bucket is never typed.** The script reads `arn:aws:s3:::usms-student-data` out of `USMSStudentDataReadWrite`'s ListBucket statement, then takes the name with the parameter expansion `${BUCKET_ARN#arn:aws:s3:::}`. Its comment says why: the name is derived from the same document as the ARN, not from a second call or a typed string.
- **It finds every policy that names the bucket.** There are **three**: `USMSStudentDataReadWrite`, `USMSStudentDataReadOnly`, and **`USMSLambdaBasic`**, which grants `usms-lambda-exec-role` `s3:GetObject`. That third one is the policy the lab mentions without naming.
- **It writes seven statements to `outputs/lab-09-bucket-policy-draft.json`:**
  - five Allows, one per principal, each limited to the actions that role already has;
  - a Deny when `aws:SecureTransport` is false, with `Principal "*"`;
  - a Deny for everyone except the five roles and the account root, written as `NotPrincipal`. A `Principal "*"` with a condition would break the rule that every other Principal is an ARN.
- **Validation:** the JSON is valid; every Principal is an ARN except the TLS Deny; the bucket ARN appears with and without `/*` in every statement; and the script contains no access-key reference (0 matches).
- **It works whether or not the bucket exists** (`head-bucket` exit 254 is recorded, not fatal), and it applies nothing.
- **The readiness file** `outputs/lab-09-lab10-readiness.txt` gives the bucket name, its existence, the three policy names with their role ARNs, a principal count of **5**, and one sentence on what changes when Lab 10 runs `create-bucket`.
- **`configs/lab-09.env`** gains `USMS_BUCKET_POLICY_DRAFT`, making **17** exports.

**Conceptual, for the S3 configuration lab:** a `NotPrincipal` Deny on real S3 must also list the assumed-role *session* ARNs, or the roles' own sessions are denied. The safer production form is `Principal "*"` with `Condition: ArnNotLike aws:PrincipalArn [...]`. The exercise's rule about Principal ARNs ruled that form out here, and the S3 lab should revisit it.

The three-sentence contrast with `USMSStudentDataReadOnly` is in `notes/lab-09-notes.md`.

---

## Floci limitations found in the exercises

| Limitation | Seen in | What real AWS does |
|---|---|---|
| `create-role --permissions-boundary` is dropped; only `put-role-permissions-boundary` stores a boundary | Ex 2 | Both store it, and `get-role` returns it |
| Group and prefix-list targets stored blank | Ex 1 | Stored and returned |
| No ENIs for the ALB, NAT or Fargate tasks; instances report `127.0.0.1` | Ex 3 | Every interface is listed with its real addresses |
| AWS-managed `ReadOnlyAccess` is an `Allow "*"` stub | Ex 4 | Read-only, though it includes `s3:Get*` |
| No `get-account-authorization-details`, no Access Analyzer, no `list-entities-for-policy` | Ex 4, 5 | Available |
