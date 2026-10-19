# Lab 08 notes

## Environment notes (2026-10-19)
- Floci 1.5.34, storage mode hybrid. kubectl uses ~/.kube/usms-lab07 (Lab 07 deviation 1); the default context kind-dso202 is not touched.
- The dso202 kind cluster was paused with docker stop for the session (RAM, and its control plane publishes host port 8081, which is Lab 08's first _lb_ports_ port). Restarted at the end.
- At the start, usms-eks-cluster was an ACTIVE record with no k3s container behind it (Floci had restarted since Lab 07). I deleted and recreated the node group and cluster records from templates/lab-07-create-*.json. The k3s Docker volume floci-floci-course-eks-usms-eks-cluster still existed, so the new k3s container came up with all of Lab 07's objects, plus a ghost Node (c2b5a5615e74, NotReady) holding six stale pods. Deleting that Node object let the ReplicaSets reschedule onto the live node. The Secret wiring from Lab 07 Step 17 survived too (it lives in the volume, not in a manifest).
- One node only (20 CPUs, 15.3 GiB). Allocatable equals capacity on this k3s: no kube-reserved/system-reserved.
- The k3s container publishes only 6443 -> 6500. Neither 8081 nor 8083 (the _lb_ports_) is published to the host.

## Step 1 and 2
usms-enrolment requests {"cpu":"50m","memory":"32Mi"}. _lb_ports_ = 8081,8083 in both configs/lab-07.env and the cluster tags (8083 replaces the lab's 8082, Lab 07 deviation 2). verify-lab-07.sh PASS=31 FAIL=0. Four Deployments (Lab 07 Exercise 1 added usms-timetable), all ClusterIP. Baseline in outputs/lab-08-baseline.txt; Lab 07 Exercise 5 artefacts present.

## Step 3 - your turn: ten times the traffic
1. Dimension 1 first (more pods): raise the HPA's maxReplicas so it can go from 2 toward 20, and load-test. Check: does CPU per pod stay near the target, and do new pods schedule, or go Pending?
2. Dimension 3 (more nodes) as soon as pods go Pending with "Insufficient cpu": raise the node group's maxSize/desiredSize (or let a Cluster Autoscaler/Karpenter do it). Check: new nodes Ready, Pending pods scheduled, and that downstream (the database) copes with ten times the connections.
3. Dimension 2 (bigger pods) only if the profile shows one pod is CPU-throttled at its 200m limit even at low request rates; it restarts every pod and changes the HPA's denominator, so recalculate the target.
4. Dimension 4 (bigger nodes) last and only by planning: new node group, cordon and drain the old one, delete it. It is never the Monday-morning lever.

## Step 4 and 5 - scaling by hand and drift
- kubectl scale 2 -> 5: ReplicaSets before 3, after 3 - no rollout, the same ReplicaSet scaled. 40 requests through the gateway reached all five pods (14/9/7/5/5).
- The watch shows the readiness gate: each new pod Running 0/1 at 1 s, 1/1 at 7 s (readinessProbe initialDelaySeconds 3, period 5). Endpoints grew only at 1/1.
- Scale-in 5 -> 2: nginx exited in about a second after SIGTERM (Completed at 13-14 s of age); the 30 s grace was the upper bound, not used.
- Drift: cluster 6, file 2; kubectl apply -> 2. kubectl diff showed replicas 2 -> 3 and exited 1. File restored (git diff empty), no .bak left.
- apply did not remove ENROLMENT_API_TOKEN/ENROLMENT_DB_PASSWORD: they were added by kubectl set env and were never in the last-applied annotation, so the three-way merge leaves them alone.

## Step 6 - QoS
All six pods Burstable (50m/200m CPU, 32Mi/128Mi memory). Node: requests 500m (2%), limits 1200m (6%) of 20 allocatable CPUs.
Your turn: kubectl set resources deployment/usms-gateway --requests=cpu=200m,memory=128Mi --limits=cpu=200m,memory=128Mi -> Guaranteed (pod phl2w replaced by 9qcmp); re-applying manifests/lab-07/40-gateway.yaml -> Burstable (pod btgs7, the original ReplicaSet hash 6875f67cdd). Each change REPLACED the pod: resources are part of the pod template, so dimension 2 always means a rollout. That is why VPA is rarely used live.
When Guaranteed: a latency-critical pod on a busy node that must be the last evicted under memory pressure and must not be CPU-throttled by a neighbour, e.g. a database or the single gateway in front of everything, at the price of reserving its peak all the time.

## Step 7 - metrics
metrics-server is present (k3s ships it): v1beta1.metrics.k8s.io True; metrics API AVAILABLE. Idle: enrolment pods 1m each (2% of 50m), gateway 4m. No --kubelet-insecure-tls needed.

## Step 8 - the HPA
Created; cpu: <unknown>/50% for the first seconds, then cpu: 2%/50%, REPLICAS 2. Conditions: AbleToScale True, ScalingActive True ValidMetricFound, ScalingLimited False DesiredWithinRange. Behavior read back exactly as written.
Worked example (lab's): 2 pods at 40m of 50m = 80%; ceil(2 x 80/50) = ceil(3.2) = 4.

## Step 9 - load, observed (outputs/lab-08-hpa-watch.txt)
- 3 load generators: CPU rose 2% -> 9% -> 40% -> 54% and stayed 51-54%. Replicas did NOT move. Reason: the HPA's default tolerance of 0.1. 54/50 = 1.08 is inside 0.9..1.1, so it does nothing. Each load generator was pinned at its 300m limit.
- Raised usms-loadgen to 6 (the lab's troubleshooting advice). 04:18:42: 67%/50% -> replicas 3. ceil(2 x 67/50) = ceil(2.68) = 3. Then CPU settled at 50% on 3 pods - the equilibrium the HPA aims for.
- Correction to the lab's example: it shows 71% -> 4 replicas and credits selectPolicy: Max. Scale-up policies are a RATE LIMIT on how far one step may go (here +2 or +100%); they never raise the result above the computed desiredReplicas. ceil(2 x 71/50) = 3, so the lab's run must have computed 4 from a higher reading. Mine went exactly to the arithmetic.
- Scale-in: load removed 04:21:42; CPU 18% at 04:22:38, 2% by 04:23:06. Replicas held at 3 until 04:27:27, then 2. That is the 300 s window counted from the last recommendation of 3 (about 04:22:24), then one step down. Event reasons, verbatim:
  - "New size: 3; reason: cpu resource utilization (percentage of request) above target"
  - "New size: 2; reason: All metrics below target"
- Second run for the screenshot (load on again): 70% -> 3, then 4 ("New size: 4; reason: cpu resource utilization (percentage of request) above target"), settling at 38% on 4.
- Two transient warnings (FailedGetResourceMetric "did not receive metrics for targeted pods (pods might be unready)") came from the Step 11 rollout: brand-new pods have no metrics for their first scrape. They cleared by themselves.

## Step 10 - node group (outputs/lab-08-step10.txt)
Before: ACTIVE, 2/4/2, t3.small, two private subnets, labels tier=app workload=usms.
aws eks update-nodegroup-config ... --scaling-config minSize=2,maxSize=6,desiredSize=3 ->
  An error occurred (400) when calling the UpdateNodegroupConfig operation: <Error><Code>InvalidArgument</Code><Message>POST requires either ?uploads, ?uploadId, ?restore or ?select parameter.</Message></Error>
list-updates and describe-update -> (404) NoSuchBucket. All three EKS update operations fall through to Floci's S3 handler: they are not implemented. Readback after: still 2/4/2. Kubernetes: one node.
This is the known issue for Lab 08 (recorded there on Floci 2.0.1; also true on 1.5.34). Alternative used: the HPA drill (Steps 8-9), which proves load changes pod replicas, and does not prove anything about nodes. verify-lab-08.sh's "node group maxSize was raised to 6" is left failing.

## Step 11 - Cluster Autoscaler vs Karpenter, and nodeSelector
Cluster Autoscaler: sees Pending pods and raises the desired capacity of an Auto Scaling group you defined in advance, one group per instance shape.
Karpenter: sees the same Pending pods and launches EC2 instances directly, choosing an instance type that fits them, within a NodePool's constraints.
Neither installed: both need IRSA (no OIDC issuer here) and real AWS APIs; Cluster Autoscaler also needs a real ASG.
Labels: "node group labels did not reach the nodes" -> applied by hand. nodeSelector workload=usms rolled out. workload=nonexistent: new pod Pending, FailedScheduling "0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector", both old pods kept serving (endpoints unchanged) because of maxUnavailable 0. Put back.
The lab's python snippet would not have matched manifests/lab-07/20-enrolment.yaml (Lab 07 Exercise 4 put topologySpreadConstraints between spec: and containers:), and it prints "nodeSelector added" even when replace() matched nothing. I anchored on the Exercise 4 comment and fail loudly if the anchor is missing. kubectl diff afterwards: exit 0.

## Step 12 - PDBs
Lab 07 Exercise 4 already declared usms-enrolment-pdb (minAvailable 1) inside 20-enrolment.yaml. Two files declaring one object undo each other on every apply (Step 5 showed "poddisruptionbudget configured" each time), so I moved it: 20-enrolment.yaml now carries a comment, 30-pdb-gateway.yaml owns it as maxUnavailable 1.
gateway-pdb minAvailable 1 -> ALLOWED 0; enrolment-pdb maxUnavailable 1 -> ALLOWED 1.
Eviction API: "Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget." kubectl delete pod: deleted and replaced, PDB silent.
kubectl drain --dry-run=client printed "evicting pod usms/usms-gateway-... (dry run)" and "node drained (dry run)": a client-side dry run does not ask the eviction API, so it does not show that a real drain would hang on the gateway. The node was not cordoned.

## Step 13 - ClusterIP and port-forward
curl to 10.43.249.84 from the host: no route. port-forward 18080:80 answered /, /enrolment/, /results/ ("Handling connection" for each - every byte through the API server). Two disqualifying properties: one tunnel to one pod (no load balancing, no failover), and it exists only while my terminal runs it.

## Step 14 - NodePort
usms-results-np 80:30080/TCP, a second Service over the same pods. Six requests via the node's InternalIP 172.17.0.3:30080 from a pod hit both results pods. With one node, "every node answers, including one with no pods" can only be stated, not shown.
From the host: localhost:30080 does not answer (not published), but http://172.17.0.3:30080/ DOES, directly: on Linux the host routes to Docker's bridge network. That is a genuine NodePort reachable from outside the cluster, not the port-forward fallback.

## Step 15 - LoadBalancer
<pending> for about 17 s, then EXTERNAL-IP 172.17.0.3: k3s's own service load balancer (klipper, events "Applied LoadBalancer DaemonSet kube-system/svclb-usms-gateway-..." and "Updated LoadBalancer with new IPs: [] -> [172.17.0.3]") fulfilled it with a svclb pod holding port 80 on the node. From the host, http://172.17.0.3/, /enrolment/ and /results/ all answered.
localhost:8081 and localhost:8083: no answer - the _lb_ports_ tag is stored but this k3s container does not publish them.
One line: type=LoadBalancer  clusterIP=10.43.249.84  nodePort=31591  external=172.17.0.3.
The three annotations are inert here. nlb-target-type: ip is Lab 05's target-type ip: register pod addresses, skip the NodePort hop.

## Step 16 - Ingress
No IngressClass, no controller pod (the k3s build runs without traefik). Ingress stored with three rules and resolved backends, CLASS <none>, no ADDRESS, Events <none>. I did not install traefik: its own LoadBalancer Service would need port 80 on the only node, which svclb-usms-gateway already holds.
Written alternative - the elbv2 calls the AWS Load Balancer Controller would make for this Ingress, in order:
1. aws elbv2 create-target-group --target-type ip (one per backend Service: usms-enrolment, usms-results, usms-gateway), health check /healthz from the healthcheck-path annotation.
2. aws elbv2 create-load-balancer --scheme internet-facing in the two public subnets (tagged kubernetes.io/role/elb=1), with the tags annotation.
3. aws elbv2 create-listener --port 80 (listen-ports) with a default action.
4. aws elbv2 create-rule, one per path (/enrolment, /results, /), with priorities it derives from the path order - then register-targets with pod IPs, kept in step with the Endpoints.
Longest prefix wins in the Ingress; Lab 05's ALB used numeric priority (10, then default).

## Step 17 - Practical 2 and Practical 4, compared with both running
Both running: ECS usms-enrolment-svc desired 2 running 2 (task def usms-enrolment:2, target group usms-enrolment-tg, type ip). Application Auto Scaling: UnknownOperationException for describe-scalable-targets and describe-scaling-policies - Lab 06 was path C, so the ECS scaling column is the configuration Lab 06 wrote, not a running policy. EKS: 4 Deployments, HPA 2..8, 5 Services, Ingress, 2 PDBs.

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | the service's desiredCount | the Deployment's spec.replicas |
| Who writes it? | Application Auto Scaling, through the service-linked role, calling ecs:UpdateService | the HPA controller in kube-controller-manager, through the scale subresource |
| Where does that thing run? | an AWS regional service outside anything I own | inside the cluster's control plane (on EKS, AWS operates it; here, inside the k3s container) |
| Where does the metric come from? | CloudWatch (ECSServiceAverageCPUUtilization, ALBRequestCountPerTarget) | metrics-server via metrics.k8s.io, scraped from the kubelets every 15 s |
| What does "50% CPU" mean - 50% of what? | of the CPU reserved for the task in the task definition | of the container's CPU request (50m), so 25m per pod |
| How is scale-in slowed down? | ScaleInCooldown 300 (Lab 06's JSON) | behavior.scaleDown.stabilizationWindowSeconds 300 plus a 1 pod / 60 s policy - observed holding 3 replicas for 5 minutes |
| What happens if there is no capacity for the new instance/pod? | nothing visible: Fargate finds capacity (or the task fails to place, rarely) | the pod stays Pending until a node is added; the HPA does not know or care |
| What creates the alarms, if anything? | target tracking creates and owns two CloudWatch alarms | nothing: the controller polls; there are no alarms |

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | 7: ALB security group, ALB, target group, listener, rule, the enrolment-sg ingress rule, and the service's loadBalancers wiring | 0. One Ingress object; the controller would create the ALB, target groups, listener and rules |
| What is the target type, and why? | ip: Fargate tasks have their own VPC address | ip (alb.ingress.kubernetes.io/target-type): with the VPC CNI, pods have their own VPC address too |
| How are targets registered and deregistered? | ECS registers tasks as they start and deregisters them (30 s delay) as they stop | the controller watches Endpoints and registers/deregisters pod IPs |
| How are competing routing rules disambiguated? | numeric rule priority (10, then default) | longest matching path; group.order between Ingress objects in one group |
| What would I change to move this to another cloud? | everything: elbv2 is AWS-only | the annotations and the ingress class; spec.rules stays |
| What is the cost of exposing ten services? | one ALB with ten rules (if I build it so), or ten ALBs | one ALB (one Ingress or one IngressGroup), billed once. Ten LoadBalancer Services would be ten NLBs |

### Two paragraphs

1. If the AWS control plane has a bad afternoon: ECS scaling stops entirely. Application Auto Scaling, CloudWatch alarms and ecs:UpdateService are all AWS regional services, so nothing scales, and I can only debug through the same APIs that are failing (the console and CLI show me stale or no data). Running tasks keep serving. On EKS the HPA lives in the cluster's control plane: if only the AWS regional APIs are degraded but the EKS control plane is up, the HPA keeps scaling pods within the nodes I have, and I can still read kubectl describe hpa and the events. What stops is anything that needs AWS: new nodes (the ASG), new load balancers, IRSA token exchange. If the EKS control plane itself is down, pods keep running and the ALB keeps sending to registered pod IPs, but nothing scales or heals, and kubectl is blind.

2. For USMS - one small team, one region, quiet for eight months and very busy for two - I would choose ECS on Fargate. There are no nodes to patch, size or pay for in the quiet months; Lab 06's scheduled actions match the known registration peaks; and capacity never runs out the way Step 9's warning describes. The strongest argument against it is portability and density: everything in Practical 2 is AWS-specific (elbv2, Application Auto Scaling, task definitions), while Practical 4's manifests ran unchanged on a local k3s, and in the two busy months Kubernetes packs many small pods onto a few nodes more cheaply than Fargate charges per task. The team's size is what decides it.

## Step 18 - persistence (outputs/lab-08-*-restart*.txt, evidence/lab-08-rebuild2.txt)
Before: HPA 2/8/50, PDBs, 5 Services (gateway LoadBalancer 31591, results-np 30080), Ingress with 3 paths, node group 2 4 2.
floci-down/up: Floci logged "Stopped k3s container for cluster usms-eks-cluster" (as on 2026-10-13). This time it removed the container AND its volume; no new k3s container started. Raw readback: "The connection to the server localhost:6500 was refused"; only the node group line (2 4 2, from the AWS half) came back. PERSISTENCE PROVEN was NOT printed.
Recovery: deleted and recreated the node group and cluster records, refreshed the kubeconfig, labelled the new node first (enrolment's nodeSelector needs it), then kubectl apply -f manifests/lab-07/, kubectl set env --from=secret (imperative, so not in any manifest - again), and every Lab 08 manifest except 20-loadgen.yaml (its replicas: 3 would start load). Readback after: identical except the gateway's auto-allocated nodePort 31591 -> 32473. The pinned 30080 is unchanged: the argument for pinning. EXTERNAL-IP came back as 172.17.0.3 because svclb runs inside the cluster.
So the Kubernetes objects are stored state only as long as the k3s container lives; on this build they survive a restart because they are in Git, not because Floci kept them. On real EKS the control plane's etcd is run by AWS and outlives anything on my side. The four Lab 3 instances were stopped by the restart again; started them.

## Step 19 - configs/lab-08.env
19 exports. USMS_INGRESS_CLASS empty (no controller, an expected exception). Node group values 2/4/2 (update not implemented). Gateway nodePort recorded as allocated at the time; it changes on every rebuild.

## Section 8 - verify-lab-08.sh
PASS=34 FAIL=1 (35 checks). The failure is the node group maxSize check, deliberately not worked around.
As given (34 checks): with KUBECONFIG unset, PASS=9 FAIL=25 - every Kubernetes check aimed at the default context (dso202, stopped). With KUBECONFIG set, PASS=32 FAIL=2: the node group check and the outputs/.gitkeep false positive (the same false positive as Labs 2-7). Changes: KUBECONFIG falls back to ~/.kube/usms-lab07; a check that kubectl's server is usms-eks-cluster's endpoint; the git check ignores .gitkeep.

## Exercise 5 part 3 - ECS or Kubernetes for USMS

Recommendation: ECS on Fargate, for USMS as it is today.

What I observed. In Practical 2 there were no nodes at all: I never sized, labelled, drained or rebuilt anything under the tasks. In Practical 4, every session started with infrastructure work on the data plane: a ghost Node holding six stale pods this morning, a node group whose labels never reached the node, a node group API that cannot be resized (update-nodegroup-config returns an S3 error on this build), and a restart that wiped the cluster's state so I had to rebuild it from Git. On real EKS most of those become patching, AMI updates, node group upgrades and PodDisruptionBudgets - work a two- or three-person team does every month, including the eight quiet ones. The HPA also showed the gap: it moved 2 -> 3 -> 4 replicas correctly, but on a full node those pods would have sat Pending, because nothing connects replicas to desiredSize unless I install and maintain a Cluster Autoscaler or Karpenter. Fargate has no second control loop to forget.

USMS's load is predictable (registration and results periods), which Lab 06's scheduled actions express directly; and one region and one team do not need Kubernetes' portability on day one.

The strongest argument against my choice is that Practical 4 was the more honest platform. Its manifests ran unchanged against a local k3s and would run against any conformant cluster; Practical 2's ALB, scalable target and task definition are AWS-only. Lab 08's Ingress expressed Lab 05's seven hand-made objects in one file, with routing by path that a reviewer can read in Git. Kubernetes also packs many small pods onto few nodes, so in the two busy months it can be cheaper than paying per Fargate task. If USMS grows to many services or a second provider, I would revisit this, and the manifests in manifests/lab-07 and lab-08 are the head start.

## Review questions (Section 14)

1. "Scales when the node hits 50% CPU" is wrong twice: averageUtilization: 50 is 50% of each pod's CPU request (50m, so 25m per pod on average), averaged over the target Deployment's pods, and the node's utilisation never enters it (this node was at 0-1% while the pods were at 54%). If someone halves the request to 25m without touching the HPA, the same real load reads as twice the percentage, so the HPA scales out at half the load and runs about twice as many pods for the same traffic. The workload ends up with more pods, but each one has a smaller guaranteed reservation - more replicas, less reserved CPU per replica, and the scheduler packs more of them per node, so under contention it has less guaranteed capacity, not more. Every percentage recorded before the change also stops being comparable.

2. Ordered plan for 10x by Monday: (a) dimension 1 - raise maxReplicas (for example to 20) and run a load test at 10x; check CPU per pod near target, p95 latency, and whether new pods go Pending. (b) dimension 3 - if Pending with Insufficient cpu, raise the node group's maxSize and desiredSize (or install Cluster Autoscaler/Karpenter); check new nodes Ready and the Pending pods scheduled, then re-run the test, and check the database and the gateway (still 2 replicas) as the next bottleneck. (c) dimension 2 only if pods throttle at their 200m limit at modest request rates; check throttling metrics, and recalculate the HPA target after changing the request. Dimension 4 - bigger instance types - cannot change in place: create a second node group with the new type, cordon and drain the old one (PDBs keep the services up), delete it. Not a Monday job.

3. Two consequences. Failure: Application Auto Scaling lives outside my workload, so a problem in my cluster or tasks cannot break it, but an AWS regional problem stops all ECS scaling and I cannot debug it from inside; the HPA lives inside the cluster, so it keeps working when AWS's other APIs are down, but if the control plane is down nothing scales and nothing tells me except kubectl failing. Visibility and ownership: the HPA's arithmetic is readable in kubectl describe hpa (conditions and reasons, which I quoted in Step 9) and its policy is a manifest in Git that kubectl diff checks; Application Auto Scaling's state lives in an AWS API and CloudWatch alarms it creates and owns, so the configuration and its history are outside my repository unless I export them.

4. The HPA (one control loop) did its job: it computed 8 and wrote spec.replicas = 8. The scheduler found no node with 50m of unrequested CPU for four of them, so they are Pending with Insufficient cpu. The node group's desiredSize is a second, separate integer (the second control loop), and nothing writes it: there is no Cluster Autoscaler or Karpenter, and the HPA does not know nodes exist. The component that normally resolves it is the Cluster Autoscaler (raising the ASG's desired capacity) or Karpenter (launching a fitting instance). Lowering the CPU request is a bad fix: it does not add capacity, it just lets the scheduler overpack the same node, and it changes the HPA's denominator, so the same load now reads as a higher percentage and the HPA asks for even more pods - the problem returns larger, and past measurements become incomparable.

5. NodePort versus LoadBalancer. A NodePort opens one port in 30000-32767 on every node; anything that can route to a node reaches it (Step 14: 172.17.0.3:30080 from my host). A LoadBalancer keeps the NodePort and adds one stable address in front, provisioned by the cloud (Step 15: svclb here, an NLB on EKS). Requirement the wrong choice fails: "students reach results at results.usms.edu.bt on port 80, and it keeps working when a node is replaced". NodePort fails it: the port is 30080, not 80, and the address is a node's IP, which changes when the node group replaces an instance. A LoadBalancer meets it: port 80, one DNS name, and the load balancer re-targets new nodes or pods by itself.

6. I would route /enrolment through usms-gateway and delete the /enrolment rule from usms-portal-ingress. Keep the gateway's route as the single path, so there is one place that decides what /enrolment means. The gateway does work the Ingress rule does not: it strips the /enrolment/ prefix before proxying (the enrolment nginx answers on /), it adds proxy headers, and it is where cross-cutting behaviour (rate limits, auth headers, the route list on /) lives for every service. Two paths to one service is a security and debugging problem: a rule added at the gateway (say, blocking an admin path) is silently bypassed by the direct Ingress path. If the gateway's extra hop is the concern, the better fix is to move those functions into Ingress annotations and remove the gateway, not to run both.

7. A PDB constrains the eviction API, and kubectl delete pod does not use the eviction API; it is a direct, deliberate delete by someone with permission, so the PDB is not consulted (Step 12 showed both). That is correct: a PDB is a promise between cooperating automation, not a lock against an administrator. Voluntary disruptions are ones something requested through an API - kubectl drain, a node group upgrade, a cluster autoscaler removing an under-used node - and the PDB is consulted. Involuntary ones - a kernel panic, the kubelet evicting under memory pressure, an instance terminated in the console, hardware failure - nobody asked, so there is nothing to refuse. Realistic save: an EKS managed node group upgrade to a new AMI drains nodes one after another; without usms-enrolment-pdb, two enrolment pods on the same node (exactly as on this single-node cluster) are evicted together and enrolment is down until replacements are Ready; with maxUnavailable 1 the drain evicts one, waits for its replacement to be ready elsewhere, then the next. Exercise 2 shows the other side: the gateway at 1 replica with minAvailable 1 would have stalled the upgrade forever, which is why the fix was 2 replicas.
