# Lab 03 exercises

## Exercise 1 - a maintenance instance

Launched usms-admin-01-host (i-64b67d0ab35000c43), t3.micro, in usms-public-subnet-b (us-east-1b),
key usms-app-key, security group usms-app-sg, no instance profile, tagged Project=USMS, Tier=admin,
Lab=03, Ephemeral=true. Used the long command-line form, and `aws ec2 wait instance-running`
instead of sleep. Not recorded in configs/lab-03.env, because Exercise 4 removes it.

Result: the Tier=admin filter returns exactly one running instance, in us-east-1b, Profile None.

### Floci finding: three failed launches before success
The first three launches (i-df96153d7c4619a2f, i-553dde39c4069fce2, i-0f5622fc19a7852c3) returned
an instance ID and then ended `terminated`; the waiter exited 255. StateReason was empty in the API.
Floci's log showed the cause: `Bind for 0.0.0.0:2200/2201/2202 failed: port is already allocated`.
Floci maps each instance's SSH port from 2200 upward, and after the Lab 03 Step 19 restart its
counter restarted at 2200 while the recovered containers (web-01, db-01, web-02) still held
2200-2202. The fourth launch got a free port and succeeded.
Real AWS has no host-port allocation, and launch failures surface in the API (StateReason), not
only in the control plane's logs.

## Exercise 2 - a self-describing bootstrap

Wrote labs/lab-03-ec2/user-data-db.sh (bash -n passes, well under 16 KB). It installs PostgreSQL,
creates database usms, writes /var/log/usms-db-bootstrap.done (instance ID + UTC timestamp), and
exits early if the marker exists. Launched usms-db-02 (i-d1df284410caddffb) in
usms-private-subnet-b with usms-db-sg.

Why the outer heredoc is quoted: so $(...), ${INSTANCE_ID} and $MARKER are written literally and
expand on the instance at boot, not in my shell.

Adaptation: IMDS is not reachable on Floci, so the script falls back to AWS_EC2_INSTANCE_ID.

Idempotence: a second run printed "usms-db bootstrap already done, exiting" and the marker was
unchanged (diff clean). A first idempotence attempt ran before the original bootstrap had finished,
so no marker existed and it started a second concurrent run. This shows that a marker protects only
after the first run completes; a lock (flock) or writing a "started" marker first would close the gap.

Byte-identity: describe-instance-attribute userData returns None on this Floci build, so the API
round-trip could not be done. The marker and the set -x log show the script executed.

Floci limitations: no systemd (postgresql-setup --initdb and systemctl failed), no sudo in the image,
so the usms database was NOT created. The marker was still written because the script has no set -e;
a production version should write the marker only after every step succeeds.

When could a re-run actually happen? Per-boot cloud-init directive; an instance rebuilt from an AMI
or volume where the marker was not preserved; manual or configuration-management invocation. The
marker makes these safe, subject to the concurrency caveat above.

## Exercise 3 - a reachability report

Wrote scripts/utilities/lab-03-reachability.sh. For each running Project=USMS instance it prints
name, private IP, public IP, verdict and reason. The verdict is computed from the subnet's route
table (a 0.0.0.0/0 route to an igw-*) and the security group (tcp/80 from 0.0.0.0/0), never from
names or tags. No resource IDs are hard-coded, it works from any directory (REPO_ROOT is derived
from the script's own path), and None/empty fields are handled by a helper function.

set -e is deliberately off: describe-* calls legitimately return empty or None for some instances,
and a missing field must produce a verdict instead of aborting the report for the rest. -u and
pipefail stay on.

Result: identical output from ~ and from labs/lab-03-ec2/. web-01, web-02 and usms-admin-01-host
are REACHABLE; db-01 and db-02 are UNREACHABLE ("no igw route on subnet") even though Floci reports
127.0.0.1 as their public address, which shows the verdict comes from routing, not the address field.

Limitation: the NO-ADDRESS branch (IGW route present, no public address) cannot be triggered on
Floci because every instance reports 127.0.0.1. It exists for real AWS, where a public-subnet
instance launched without a public IP and without an Elastic IP is in exactly this state.

## Exercise 4 - right-size and clean up

### Scale up or scale out?
I would scale out. The workload is mostly reads, with 400 concurrent users at midday and idle
overnight, so two or more small instances in different AZs behind a load balancer fit it. Scaling
up (one bigger instance) raises the ceiling but does nothing about overnight idle time, because a
larger instance costs the same per hour whether it is busy or not, and it leaves a single point of
failure. Scaling out lets an Auto Scaling group (Lab 6) hold fewer instances overnight, so idle
time costs less. We already run web-01 (us-east-1a) and web-02 (us-east-1b), so the shape exists.

### Why 85 percent sustained is a problem on a t3
t3 instances are burstable. They earn CPU credits while running below a baseline and spend them
when running above it. A t3.micro's baseline is only about 10 percent of each vCPU (AWS burstable
documentation; not re-checked here). Running at 85 percent through midday spends credits much faster
than they are earned. What happens next depends on the credit mode. In standard mode the instance
is throttled to its baseline once credits run out. In unlimited mode, which is the default for t3
launches, it keeps full speed and AWS bills surplus credits (about USD 0.05 per vCPU-hour for Linux,
quoted from memory and to be verified). Roughly (0.85 - 0.10) x 2 vCPU x 0.05 = USD 0.075 per
hour, several times the instance's own 0.0104 per hour. So the t3.micro looks cheap but either
throttles or is billed far above its list price. I tried describe-instance-credit-specifications
to see which mode ours is in; the result is recorded in the audit output.

### Monthly cost comparison (us-east-1, Linux on-demand, 730 hours/month)
| Option | Calculation | Per month |
|---|---|---|
| Current: 1 x t3.micro | 0.0104 x 730 | USD 7.59, but throttled or surcharged at 85% CPU |
| Scale up: 1 x t3.medium | 0.0416 x 730 | USD 30.37, still burstable, no overnight saving |
| Scale out: 2 x t3.small, always on | 2 x 0.0208 x 730 | USD 30.37 |
| Scale out with scheduling: 2 x t3.small for 12 h, 1 for 12 h | 1.5 x 0.0208 x 730 | USD 22.78 |
| Same fleet on Spot (batch or tolerant work only) | 0.0064-0.0087 x 730 per instance | about USD 4.70-6.35 each, interruptible |
Not included: a load balancer, data transfer and EBS storage, which I did not price. Each public
IPv4 address adds USD 0.005 per hour (about USD 3.65/month), whether in use or idle. Instances
behind a load balancer need not carry their own public address.

Sources: doit.com EC2 t3 price pages (t3.micro, t3.small, t3.medium), Holori t3.micro calculator,
and the AWS News Blog post "New - AWS Public IPv4 Address Charge + Public IP Insights".
Prices should be re-checked on the AWS pricing page before relying on them.

### Cleanup decisions (see the deletions below)
Delete: the Exercise 1 admin host (Ephemeral=true). Keep: usms-web-01, usms-web-02, usms-db-01,
usms-web-data-vol, usms-web-eip, and usms-nat-eip. The NAT's Elastic IP shows no instance
association but is in use by the NAT gateway, so it is not an idle address.

### Deletions executed
Audit first (read-only): credit mode could not be checked (describe-instance-credit-specifications
is UnsupportedOperation on Floci). The audit found one ephemeral instance and three orphaned volumes.

1. terminate-instances on usms-admin-01-host (i-64b67d0ab35000c43). Its root volume was deleted with
   it (DeleteOnTermination True), and its two port-forward containers disappeared.
2. delete-volume on three orphaned root volumes (vol-1f1bbb557a007b7d4, vol-31fe0d0df8b8101f3,
   vol-392c2b899e9f564e5). They belonged to the three launches that failed with a port conflict
   (Exercise 1). Floci marked those instances terminated but left the volumes in-use. On real AWS
   they would have been deleted at termination, so this is a Floci limitation, and on a real account
   it would be storage billed for nothing.

Deliberately NOT deleted: usms-web-data-vol (KEEP, and only unattached because attach-volume is
unsupported), usms-nat-eip (no instance association, but in use by the NAT gateway, not idle),
usms-web-eip (associated), and usms-db-02 (kept until the Exercise 2 evidence is captured).

Verification afterwards: verify-lab-03.sh still reports PASS=32 FAIL=5, the same five [floci]
failures as before, so the cleanup removed nothing the lab depends on.
