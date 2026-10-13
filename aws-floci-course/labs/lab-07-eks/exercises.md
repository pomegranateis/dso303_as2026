# Lab 07 - Independent Lab Exercises

Environment: Floci v1.5.34, AWS CLI v2.31.35, kubectl against `usms-eks-cluster` (support path A: a real k3s cluster, Kubernetes v1.34, **one node**). The kubeconfig is `~/.kube/usms-lab07` (see the README).

Labels used throughout: **Observed** (seen in command output), **Conceptual** (reasoned, not run), **Floci limitation** (this emulator behaves differently from real AWS). Full output is in [`evidence/`](evidence/).

---

## Exercise 1 - Basic: a fourth microservice

`manifests/lab-07/70-timetable.yaml` holds all three objects: the ConfigMap `usms-timetable-conf` (an nginx template answering JSON with the service and pod names, plus `/healthz`), the Deployment `usms-timetable` (1 replica, `nginx:1.27-alpine`, labels `app`/`project`/`tier`, requests 50m CPU and 32Mi memory, limits 200m and 128Mi, a readiness probe on `/healthz`), and a ClusterIP Service on port 80. I wrote it by hand from `30-results.yaml`'s structure and validated it with `kubectl apply --dry-run=client` first.

Observed ([evidence/lab-07-ex1.txt](evidence/lab-07-ex1.txt)): four Deployments and four Services in `usms`; `usms-timetable` 1/1 with one endpoint. A busybox pod fetching `http://usms-timetable.usms.svc.cluster.local/` got:

```
{"service":"usms-timetable","pod":"usms-timetable-cf6b9c8fb-gx4sv","campus":"rtc","version":"1.0.0"}
```

---

## Exercise 2 - Intermediate: route to it, and prove the route

I added a `location /timetable/` block to the gateway's ConfigMap in `manifests/lab-07/40-gateway.yaml` (and `/timetable/` to the root's route list), then re-applied the file. No `kubectl edit`.

Observed ([evidence/lab-07-ex2.txt](evidence/lab-07-ex2.txt)):

1. `kubectl apply`: `configmap/usms-gateway-conf configured`, `deployment.apps/usms-gateway unchanged`. Through the gateway, `/timetable/` returned **404**: the ConfigMap changed, but nginx reads its configuration only when the pod starts, and the pod template had not changed, so no new pod started.
2. `kubectl rollout restart deployment/usms-gateway` writes a `restartedAt` timestamp into the pod template (`2026-10-13T08:47:33+06:00`). That was the command that caused the new ReplicaSet: `usms-gateway-58854c9ffd` was replaced by `usms-gateway-6875f67cdd`, and `rollout history` went from revision 1 to revisions 1 and 2. Of Step 18's two commands, `kubectl annotate` changes only the Deployment's own metadata, so `rollout restart` is the one that works when the template has not changed.
3. All three routes in one command:

```
/enrolment/ -> {"service":"usms-enrolment","pod":"usms-enrolment-7d8557c58d-76d6j",...}
/results/   -> {"service":"usms-results","pod":"usms-results-7fc784c47f-4lg22",...}
/timetable/ -> {"service":"usms-timetable","pod":"usms-timetable-cf6b9c8fb-gx4sv",...}
```

---

## Exercise 3 - Problem solving: find the misconfiguration

I applied the manifest exactly as given ([evidence/lab-07-ex3-broken.yaml](evidence/lab-07-ex3-broken.yaml)) and found both faults with commands ([evidence/lab-07-ex3-diagnose.txt](evidence/lab-07-ex3-diagnose.txt)):

| # | Command | What it showed |
|---|---|---|
| 1 | `kubectl get endpoints usms-broken` | `<none>`: the Service sends traffic nowhere |
| 2 | `kubectl describe svc usms-broken` | `Selector: app=usms-broken,version=v2` |
| 3 | `kubectl get pods -l app=usms-broken,version=v2` / `--show-labels` | 0 pods match; the pods carry `version=v1` |
| 4 | `kubectl get pods -l app=usms-broken` | both pods `Running` but `0/1`, never Ready |
| 5 | `kubectl describe pod` | readiness probe `http-get http://:http/healthz` |
| 6 | `kubectl exec <pod> -- wget -S http://127.0.0.1/healthz` and `/` | `/healthz` -> **404 Not Found**, `/` -> 200 OK |

**Diagnosis:** the Service selects `version: v2` while the pods are labelled `version: v1`, so it matches nothing; and the readiness probe asks the base nginx image for `/healthz`, which it does not serve, so the pods never become Ready and could never be endpoints even if selected.

**The fix** is one line per fault ([evidence/lab-07-ex3-fix.txt](evidence/lab-07-ex3-fix.txt)). The brief says "exactly one line", but it also says there are two independent problems and that fixing one is not enough, so it takes one line each:

```
25c25   <   path: /healthz     >   path: /
37c37   <   version: v2        >   version: v1
```

After the selector fix alone, both pods appeared under the endpoints' `notReadyAddresses` and the Service still had no ready endpoints. After the probe fix as well, the Service had two endpoints and a request returned 200. `usms-broken` was then deleted (a CLEAN UP item).

**A mistake I made and fixed.** My first attempt to copy the broken manifest out of the lab page picked up Step 13's `usms-enrolment` Deployment, because the page's table of contents also contains the exercise title, and `kubectl apply` applied that block before failing on the rest. I checked: the block was identical to the committed `20-enrolment.yaml`, the Secret variables were still set (`apply` leaves fields it did not create alone), and the Deployment stayed 2/2. It only refreshed the last-applied annotation. Then I extracted the right manifest and started again.

---

## Exercise 4 - Challenge: survive a node going away

**What changed in `20-enrolment.yaml`:**

- **`topologySpreadConstraints`** on the pod template: `maxSkew: 1`, `topologyKey: kubernetes.io/hostname`, `whenUnsatisfiable: ScheduleAnyway`, selecting `app: usms-enrolment`.
- **A new object, `usms-enrolment-pdb`**, a PodDisruptionBudget with `minAvailable: 1` for `app: usms-enrolment`.

**Why these two.**

- **The spread constraint** answers "not all capacity on one node". It tells the scheduler to keep the two replicas' counts per node within one of each other, which on two or more nodes means one replica each, so losing a node loses half the capacity, not all of it. I made it **advisory** (`ScheduleAnyway`): if only one node can take pods, both still schedule there rather than one staying Pending. During a node failure a Pending replica is worse than two replicas on one node. `podAntiAffinity` with `requiredDuringScheduling...` would be the hard version, and is the wrong choice for a two-replica service on a small cluster.
- **The PodDisruptionBudget** answers "never below one healthy pod during a voluntary disruption". It is **enforced** by the eviction API: a `kubectl drain`, a node group upgrade or the cluster autoscaler must evict through it and is refused while eviction would leave fewer than one ready pod. It does not protect against involuntary loss (a node crashing); that is what the spread is for.
- **"Which node each pod is on, from the cluster itself"** is `kubectl get pods -l app=usms-enrolment -o wide`, whose `NODE` column the scheduler fills in. Each pod also reports its node in its own JSON response (`"node"`, from the `NODE_NAME` downward-API variable).

**What this build allows.** **Floci limitation:** the cluster has one node, so the spread cannot place pods on different nodes; both are on `c2b5a5615e74` ([evidence/lab-07-ex4-apply.txt](evidence/lab-07-ex4-apply.txt)). On a two-node cluster, `kubectl get pods -o wide` would show one replica per node, and stopping one node would leave the other replica serving.

**Demonstrated: the PDB under a real drain** ([evidence/lab-07-ex4-drain.txt](evidence/lab-07-ex4-drain.txt)). A busybox pod sent one request a second for 60 seconds to the enrolment Service, while I ran `kubectl drain <node> --pod-selector=app=usms-enrolment` with a 40-second timeout. Only the enrolment pods were evicted, so the gateway and the smoke test were unaffected.

- The node was cordoned and the first pod (`…hhg6h`) was **evicted**.
- Its replacement (`…6nt7h`) stayed **Pending**, because the only node was cordoned.
- The second eviction was **refused**: "Cannot evict pod as it would violate the pod's disruption budget", retried until the timeout. The PDB showed `ALLOWED DISRUPTIONS 0`.
- After `kubectl uncordon`, the replacement started and the Deployment was back to 2/2.
- **`smoke: ok=60 failed=0`**: the Service never lost its last pod.

---

## Exercise 5 - Integration: prepare what Lab 08 needs, using what Lab 01 built

**Part 1, CPU baseline** ([evidence/lab-07-cpu-baseline.txt](evidence/lab-07-cpu-baseline.txt)). The metrics API is **present** on this build (`kubectl get --raw /apis/metrics.k8s.io/v1beta1` answered; k3s ships metrics-server), so `kubectl top` worked and the numbers are measured, not invented:

```
cpu request per pod: 50m
pod usms-enrolment-8549846ddd-6nt7h  cpu 4m  = 8.0% of the 50m request  memory 14Mi
pod usms-enrolment-8549846ddd-bcvr9  cpu 1m  = 2.0% of the 50m request  memory 15Mi
```

These are idle pods with no traffic; Lab 08's HPA compares this percentage with its target.

**Part 2, readiness** ([evidence/lab-07-lab06-readiness.txt](evidence/lab-07-lab06-readiness.txt)). Everything was read from IAM: the policy ARN from `list-policies`, its default version from `get-policy`, and its document from `get-policy-version`.

```
policy ARN          : arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite (default version v1)
roles carrying it   : usms-ec2-app-role usms-ecs-task-role usms-eks-node-role
bucket ARN          : arn:aws:s3:::usms-student-data   (the bucket: ListBucket, GetBucketLocation, Deny DeleteBucket)
object ARN          : arn:aws:s3:::usms-student-data/* (its objects: GetObject, PutObject, DeleteObject)
bucket exists?      : no - head-bucket exit 254: An error occurred (404) ... Not Found
```

The roles were found by asking every role for its attached policies, because `list-entities-for-policy` is unsupported (as in Lab 04). Both files are in `outputs/`, and `git check-ignore -v` names `.gitignore:7:outputs/*` for each; the copies in `evidence/` are what is committed.

**Part 3**, which of the 21 variables Lab 08 needs and why, is in `notes/lab-07-notes.md`.

---

## Floci limitations found in the exercises

| Limitation | Seen in | What real EKS does |
|---|---|---|
| One node only, so the spread constraint cannot spread | Ex 4 | Node group of two or more nodes across the private subnets |
| `roles carrying it` must be found role by role | Ex 5 | `list-entities-for-policy` answers directly |
