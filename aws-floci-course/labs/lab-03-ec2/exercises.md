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
