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
