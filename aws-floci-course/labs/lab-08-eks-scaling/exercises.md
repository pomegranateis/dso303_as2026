# Lab 08 - Independent Lab Exercises

Environment: Floci v1.5.34, AWS CLI v2.31.35, kubectl against `usms-eks-cluster` (support path A: a real k3s cluster, Kubernetes v1.34, **one node**). The kubeconfig is `~/.kube/usms-lab07` (see the README).

Labels used throughout: **Observed** (seen in command output), **Conceptual** (reasoned, not run), **Floci limitation** (this emulator behaves differently from real AWS). Full output is in [`evidence/`](evidence/).

---

## Exercise 1 - Basic: a second autoscaler

`manifests/lab-08/11-hpa-results.yaml`, `autoscaling/v2`: min 2, max 6, CPU 60%, scale-up at most 2 pods per 30 s, scale-in behind a 180 s window (1 pod per 60 s). `usms-results` already requested `cpu 50m` (Lab 7 Step 14), so the denominator exists. A client-side dry run passed first (`created (dry run)`), then the real apply.

Observed ([evidence/lab-08-ex1.txt](evidence/lab-08-ex1.txt)):

```
NAME                 REFERENCE                   TARGETS       MINPODS   MAXPODS   REPLICAS
usms-enrolment-hpa   Deployment/usms-enrolment   cpu: 2%/50%   2         8         2
usms-results-hpa     Deployment/usms-results     cpu: 2%/60%   2         6         2
```

Conditions: `ScalingActive True ValidMetricFound`, `ScalingLimited False DesiredWithinRange`.

**Why 60% and not 50%:** results is read-mostly, with cheap, uniform requests and no write path to protect, so each pod can run hotter before another is worth adding, while enrolment's spiky, write-heavy registration traffic needs more headroom per pod.

---

## Exercise 2 - Intermediate: make the gateway drainable

**The fix is the workload, not the PDB.** `usms-gateway-pdb` keeps `minAvailable: 1`. One replica with a floor of one leaves zero disruptions, so I changed `manifests/lab-07/40-gateway.yaml`:

- `replicas: 1` → `replicas: 2`
- a `topologySpreadConstraints` block on `kubernetes.io/hostname` (`maxSkew 1`), so the two pods prefer different nodes

Observed ([evidence/lab-08-ex2.txt](evidence/lab-08-ex2.txt)): `ALLOWED DISRUPTIONS` went **0 → 1**. Then I repeated Step 12's eviction API call, which had been refused:

```
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
usms-gateway-pdb   1   N/A   0          <- while the replacement starts
--- a second eviction straight away is refused ---
Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget.
usms-gateway-pdb   1   N/A   1          <- replacement Ready
```

So a drain can now proceed one pod at a time, and the floor of one is still enforced.

**One node.** Both gateway pods are on `4d622ea57c95`; `ScheduleAnyway` lets them schedule side by side because there is nowhere else. With two or more nodes they would land on different nodes. To *require* it I would use `whenUnsatisfiable: DoNotSchedule` (or a required pod anti-affinity on `kubernetes.io/hostname`), but that would leave the second pod Pending on this cluster, so I kept the advisory form and say so here.

**A problem this exposed, and the fix.** Re-applying `40-gateway.yaml` briefly turned `usms-gateway` back into **ClusterIP** (and its nodePort changed), because that file still declared the Service that `manifests/lab-08/50-service-loadbalancer.yaml` redefines. Two files declaring one object undo each other: the same problem as the PDB in Step 12. I moved the Service out of `40-gateway.yaml` (a comment marks where it went). After that, both `kubectl diff -f manifests/lab-07/40-gateway.yaml` and `kubectl diff -f manifests/lab-08/50-service-loadbalancer.yaml` exit **0**. Because of the move, the cleanup script uses the lab's own `kubectl patch ... ClusterIP` again.

`verify-lab-07.sh` checked the gateway for exactly 1 ready replica; it now checks for at least 1 (PASS=31 FAIL=0).

---

## Exercise 3 - Problem solving: the autoscaler that will not act

The manifest was applied exactly as given ([evidence/lab-08-ex3-broken.yaml](evidence/lab-08-ex3-broken.yaml)) and diagnosed with commands ([evidence/lab-08-ex3-diagnose.txt](evidence/lab-08-ex3-diagnose.txt)), in this order:

1. `kubectl get hpa usms-reports-hpa` → `cpu: 0%/70%   MINPODS 4   MAXPODS 4   REPLICAS 4`. A number, **not** `<unknown>`.
2. `kubectl describe hpa` → `ScalingLimited True TooFewReplicas: the desired replica count is less than the minimum replica count`.
3. `kubectl get pods -o custom-columns=...QOS,REQ,LIM` → every pod **`Guaranteed`**, `requests map[cpu:200m memory:128Mi]`, though the Deployment's template has **no** requests.
4. `min=4 max=4`.

**Fault 1, the missing request (the `<unknown>` one, in principle).** The container sets only `limits`. **Observed, and different from what the lab expects:** the API server *defaults requests to limits* when only limits are given, so the pods got an implicit 200m request and the HPA could compute 0%. The fault is real but latent. The HPA's denominator, and 200m reserved on the node for every pod, come from a default nobody chose. The HPA would only scale at 70% of 200m = 140m per pod, and the pods are Guaranteed by accident. To show the `<unknown>` the lab describes, I removed the resources block entirely ([evidence/lab-08-ex3-contrast.txt](evidence/lab-08-ex3-contrast.txt)):

```
usms-reports-5d948cf458-7mx7f   BestEffort
usms-reports-hpa   Deployment/usms-reports   cpu: <unknown>/70%   4   4   4
ScalingActive   False   FailedGetResourceMetric  ... missing request for cpu in container reports of Pod ...
```

**Fault 2, `minReplicas == maxReplicas` (prevents action even with perfect metrics).** The HPA clamps every answer to [4, 4], so 4 is the only value it can ever write. Under any load the replica count never changes.

**Fixes, one field each** ([evidence/lab-08-ex3-fixed.yaml](evidence/lab-08-ex3-fixed.yaml)):

```
>             requests:
>               cpu: "50m"        # FIX 1
<   minReplicas: 4
>   minReplicas: 2       # FIX 2
```

(Fix 1 adds a `requests:` key with one field under it.) After applying ([evidence/lab-08-ex3-fix.txt](evidence/lab-08-ex3-fix.txt)): pods `Burstable 50m/200m`, `cpu: 0%/70%`, `MINPODS 2 MAXPODS 4`, `ScalingLimited False DesiredWithinRange`, so it has room to move both ways. One more Step 5 lesson came up on the way: applying the fixed file set replicas straight to 2, because the Deployment's own `replicas: 2` overwrote what the HPA had written. At idle the HPA then reported `ScalingLimited True TooFewReplicas` again, but now that is the healthy case: it wants 1 and the floor holds 2.

`usms-reports` and its HPA were deleted afterwards.

---

## Exercise 4 - Challenge: expose the results service properly

**Design.** I added a second Ingress object, `manifests/lab-08/61-ingress-results.yaml`, but not a second load balancer:

| Requirement | How | Rung |
|---|---|---|
| stable address, normal HTTP port | the existing ALB's DNS name, port 80 (`listen-ports`) | Ingress (4) |
| a path of its own | `/exam-results` → `usms-results` (Prefix) | Ingress (4) → ClusterIP (1) |
| from the university network only | `alb.ingress.kubernetes.io/conditions.usms-results`: a `source-ip` condition (203.0.113.0/24 stands in for the university's egress range) | listener rule |
| enrolment not given the same exposure | the condition is on the results rule only; `/enrolment` gets no university-only route | – |
| no second load balancer | `alb.ingress.kubernetes.io/group.name: usms-portal` on **both** Ingress objects, so the AWS Load Balancer Controller merges their rules onto **one** ALB; `group.order` 10 and 20 order them | – |

**Why not a second `type: LoadBalancer` Service:** it would create a second NLB that bills by the hour whether or not anyone uses it, and an NLB works at layer 4, so it cannot route by path or by source IP on a path.

**Is the existing Ingress the answer?** It's a starting point, but it has the wrong shape. It already routes `/results` to the internet with no restriction, and it also routes `/enrolment` straight to the pods (Review Question 6). A separate object for the Examinations Office keeps its rule, its owner tag and its restriction reviewable on their own, while the group keeps the bill single.

**What the build demonstrates** ([evidence/lab-08-ex4.txt](evidence/lab-08-ex4.txt)):
- Observed: both Ingress objects stored in group `usms-portal` (orders 20 and 10); the `/exam-results` rule resolved to both results pods; the backend answering at `http://usms-results.usms.svc.cluster.local/exam-results`; and results already reachable today at a stable address on port 80 through rung 3, `http://172.17.0.3/results/`.
- Conceptual (no controller here): the ALB rule with the source-IP condition, the merged IngressGroup, and the `ip` target group. On real EKS these come from the AWS Load Balancer Controller acting on exactly these annotations.

**Cost.** One ALB is billed per hour plus LCUs. At us-east-1 list prices that is about $0.0225/hour, roughly $16 a month, plus $0.008 per LCU-hour. Adding a rule to the existing ALB adds no hourly charge; extra rule evaluations only count toward LCUs beyond the first 10 rules. A second load balancer would add another ~$16 a month before any traffic. (Prices from the AWS ELB pricing page as I know them; check them before quoting.)

**Failure mode if the cluster is unavailable.** The ALB lives in the VPC, outside the cluster, so the address keeps answering:
- If the **control plane** is down but the nodes and pods are fine, the ALB keeps sending to the registered pod IPs. Results stays up, but nothing re-registers when a pod moves, so targets slowly go stale.
- If the **pods or nodes** are down, every target fails its `/healthz` check and the ALB returns **503** at a stable address, which is at least a clear failure.
- If the **controller** is down, the existing ALB configuration keeps working; changes to the Ingress just aren't applied.
- The Examinations Office loses results entirely only if the ALB itself is deleted, which happens when someone deletes the last Ingress in the group. That is why `lab-08-cleanup.sh` deletes the Ingress first and why the owner tag is on the rule.

---

## Exercise 5 - Integration: the artefacts Lab 10 needs

**Part 1** ([evidence/lab-08-scaling-evidence.json](evidence/lab-08-scaling-evidence.json)): assembled by `python3` from `kubectl get hpa -o json`, `kubectl get deploy -o json`, `aws eks describe-nodegroup` and `kubectl get nodes`, with a UTC timestamp. It holds the HPA's full spec and status (current 2%, 1m average), the Deployment (2/2, request 50m, `nodeSelector workload=usms`) and the node group's scaling configuration **as it really is (2/4/2)**, with a note stating that the Step 10 update could not be applied. `python3 -m json.tool` accepts it (3,128 bytes).

**Part 2** ([evidence/lab-08-lab06-readiness.txt](evidence/lab-08-lab06-readiness.txt)): re-derived, not copied from Lab 07.
- The policy ARN comes from `list-policies`, its default version `v1` from `get-policy`, and the bucket ARN `arn:aws:s3:::usms-student-data` is read **out of the document's `Resource`** with `python3`.
- Roles carrying it: `usms-ec2-app-role usms-ecs-task-role usms-eks-node-role`. They were found role by role, because `list-entities-for-policy` returns `UnsupportedOperation`.
- The bucket does not exist (`head-bucket` exit 254, 404). Lab 10 creates it.
- **IRSA:** ServiceAccount `usms/usms-enrolment-sa` would carry `eks.amazonaws.com/role-arn: arn:aws:iam::000000000000:role/usms-enrolment-irsa-role`. That is a **new** role trusting the cluster's OIDC provider for `system:serviceaccount:usms:usms-enrolment-sa` only. It is **not** `usms-eks-node-role`, because a node role is inherited by every pod on the node, and IRSA exists to narrow that to one ServiceAccount. It cannot be created here: the OIDC issuer is `None`.

Both files are in `outputs/`, and `git check-ignore -v` names `.gitignore:7:outputs/*` for each; the copies in `evidence/` are what is committed.

**Part 3**, "ECS or Kubernetes for USMS" (317 words), is in `notes/lab-08-notes.md`.

---

## Floci limitations found in the exercises

| Limitation | Seen in | What real EKS does |
|---|---|---|
| One node, so spreading cannot spread | Ex 2 | A node group across private-a and private-b |
| No ingress controller; Ingress objects are stored, never fulfilled | Ex 4 | The AWS Load Balancer Controller builds the ALB, the rules and the source-IP condition |
| No OIDC issuer, so no IRSA role can be trusted | Ex 5 | Every cluster has an issuer |
| `list-entities-for-policy` unsupported | Ex 5 | Answers directly |
| `update-nodegroup-config` not implemented, so the evidence JSON records 2/4/2 | Ex 5 | The scaling config changes and the ASG follows |
