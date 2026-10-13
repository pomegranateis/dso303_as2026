# Lab 07 notes

## Lab 07 support path
Probed on 2026-10-12 (outputs/lab-07-support-probe.txt).
PATH A  - use aws eks throughout
- eks list-clusters answers ({"clusters": []}); describe-cluster and list-nodegroups on a missing name return ResourceNotFoundException - real API answers, not "unknown operation".
- kubectl /usr/local/bin/kubectl installed; k3d MISSING (only needed on path B).
- Path A was provisional until create-cluster actually started a cluster (Step 8).

## Environment notes
- Free memory at the start: 1.8 GiB available of 15 GiB. Another, unrelated kind cluster (dso202, three kindest/node containers, from another module) was running and is left untouched.
- My default kubectl context is kind-dso202 (plus minikube). So that this lab does not switch the context another module relies on, Lab 07 uses its own kubeconfig file, ~/.kube/usms-lab07, passed with KUBECONFIG; the default ~/.kube/config is not changed.
- Port 8082 was already in use on the host (127.0.0.1:8082, a local process not owned by Docker). The cluster's _lb_ports_ tag therefore uses 8081,8083 instead of the lab's 8081,8082; Lab 08 must use 8083 where the lab says 8082.

## Step 3: "EKS is just ECS with different names"
False: EKS has a data plane you run yourself - EC2 nodes in your account, with a kubelet, a container runtime and a CNI that you patch and pay for as instances, and a second IAM role for them - while ECS on Fargate has almost nothing in that column. And EKS's API is Kubernetes, served from the cluster's own endpoint and portable to any conformant cluster, not an AWS API.
Nearly true: both answer the same question the same way - a control plane AWS runs keeps a declared number of copies of a container running and replaces failed ones - so a Deployment is close to a service, a pod spec to a task definition, and a Service to service discovery.

## Steps 4 to 7: IAM and the cluster security group
Trust: usms-eks-cluster-role trusts eks.amazonaws.com; usms-eks-node-role trusts ec2.amazonaws.com (a node is an EC2 instance). Permissions: USMSEKSClusterPolicy (3 statements, ending in the region Deny) on the cluster role; USMSEKSNodePolicy (5 statements, ending in the region Deny) and Lab 1's USMSStudentDataReadWrite, unchanged, on the node role.
usms-eks-cluster-sg sg-77d25192a5b480a71 in usms-vpc, tcp/443 from 10.0.0.0/16 only (an administrative API, unlike Lab 05's public load balancer group).
Floci limitation: iam list-entities-for-policy is unsupported (UnsupportedOperation), as in Lab 04. Asked per role instead: usms-ec2-app-role (Lab 3), usms-ecs-task-role (Lab 4) and usms-eks-node-role all carry USMSStudentDataReadWrite - three holders, one policy, never edited.
Floci limitation: policies are stored, not enforced, so these documents are judged by reading them.

## Step 8: create the cluster - Path A confirmed, after two problems
1. First attempt (as usms-developer-role): "Read timeout on endpoint URL". Floci pulls rancher/k3s:latest inside the create-cluster call; on this connection the pull did not finish within the CLI's 60 s read timeout, the CLI retried, and Floci's own pull gave up after 5 minutes ("Transient image pull failure ... Could not pull image: Downloading", 3 attempts). The cluster record was left FAILED, with no endpoint and no k3s container.
2. Fix: pulled rancher/k3s:latest directly with docker pull (243 MB; Floci uses the host's Docker, so the image is then local), deleted the FAILED record (my own, from the failed attempt) and re-ran create-cluster with --cli-read-timeout 300. It returned CREATING and a k3s container started at once.
Also: the kind cluster dso202 (another module) was stopped with docker stop for this session to free memory (1.8 -> 3.9 GiB available); its data and volumes are kept and it is restarted at the end. Port 8082 was busy, so _lb_ports_ is 8081,8083.
Floci limitation: an image pull longer than the CLI timeout leaves a FAILED cluster rather than a cluster that finishes later. Real EKS create-cluster returns CREATING immediately and provisions asynchronously.

## Step 9: the cluster
ACTIVE on the first poll (real AWS: 10 to 15 minutes). Endpoint https://localhost:6500; role usms-eks-cluster-role; four subnets; sg usms-eks-cluster-sg; tags include _lb_ports_=8081,8083.
Floci limitations: resourcesVpcConfig.vpcId is "" (real AWS derives it from the subnets); the API is on host port 6500, not the lab's 6443.
Your turn: aws eks describe-cluster --name usms-eks-cluster --query 'cluster.[version,identity.oidc.issuer]' --output text -> "1.30  None".
The OIDC issuer is the URL of the cluster's identity provider: IAM trusts tokens it signs, which is what lets a Kubernetes service account assume an IAM role (IRSA, Step 21). None means this build has no issuer, so IRSA cannot be set up here.

## Step 10: the node group
usms-eks-nodes ACTIVE immediately: private-a and private-b only, min 2 / max 4 / desired 2, nodeRole usms-eks-node-role, labels workload=usms tier=app, t3.small, AL2023_x86_64_STANDARD.
Floci limitation: the node group is a record only. No instances or node containers are created, t3.small is not provisioned, and its labels never reach a node (Step 11).

## Step 11: kubectl
aws eks update-kubeconfig --name usms-eks-cluster --alias usms-eks --kubeconfig ~/.kube/usms-lab07 (a separate file, so the default context kind-dso202 is unchanged - checked after). The user entry runs aws eks get-token, and it works against Floci.
kubectl cluster-info: control plane, CoreDNS and metrics-server at https://localhost:6500. kubectl auth can-i create deployments --all-namespaces: yes. api-resources includes configmaps, deployments.apps, pods, secrets, services.
Floci limitations: ONE node, the k3s server itself (Ready, roles control-plane), not two workers in the private subnets; Kubernetes v1.34.1+k3s1, not the 1.30 requested (Floci runs rancher/k3s:latest whatever version is asked for); the node has no workload/tier labels; node INTERNAL-IP 172.17.0.3, a Docker address, not a VPC address.

## Step 12: namespace
usms created and set as the context's default namespace. Labels project=usms, tier=app, lab=05a - "05a" is the lab text's own value (an older name for this lab), kept as written.

## Steps 13 to 15: the three microservices
usms-enrolment: rolled out, 2/2, ReplicaSet usms-enrolment-6965b8dbbb, pods 10.42.0.5 and .6, ClusterIP 10.43.149.214 with no external IP, two endpoints. A request from a busybox pod to usms-enrolment.usms.svc.cluster.local returned {"service":"usms-enrolment","pod":"...qr5dl","env":"laboratory","version":"1.0.0"}.
usms-results: 2/2. Strategies: usms-enrolment RollingUpdate maxUnavailable 0, usms-results maxUnavailable 25%. Two endpoints each.
usms-gateway: 1/1. Five pods Running; the gateway log has no emerg lines, and the kubelet's probes hit /healthz with 200.
Pod addresses are 10.42.0.x from k3s's own pod network (flannel), not VPC addresses: on real EKS the VPC CNI gives each pod an address from the private subnets.

## Step 16: service discovery
nslookup from inside the cluster: usms-enrolment.usms.svc.cluster.local -> 10.43.149.214 and usms-results... -> 10.43.188.74, answered by CoreDNS at 10.43.0.10 - exactly the two Services' ClusterIPs.
Through the gateway: / answers as usms-gateway with routes /enrolment/ and /results/; /enrolment/ reaches an enrolment pod and /results/ a results pod.
12 requests via /enrolment/ were answered by both enrolment pods (9 and 3). The gateway's ConfigMap contains no IP address (grep count 0) - only the two DNS names.
Your turn: deleted usms-enrolment-...qr5dl while a pod sent 40 requests through the gateway, 0.5 s apart: ok=40 failed=0. The tally shows the old pod (7, before deletion), the surviving pod (26) and the new pod usms-enrolment-...zhxkd (7). Events: "Killing ... qr5dl" and "replicaset/usms-enrolment-6965b8dbbb Created pod: ...zhxkd" in the same second - the ReplicaSet replaced it, not me, and the gateway was never restarted.

## Step 17: ConfigMaps and Secrets
manifests/lab-07/50-secret.yaml generated with kubectl create secret generic ... --dry-run=client -o yaml, holding two deliberately dummy values (floci-dummy-token-not-a-real-secret, floci-dummy-password). It is committed only because the lab uses it as a Git-hygiene example; in a real system a base64 value in a committed file is a plaintext value in Git history forever, and the file would go in outputs/ or not exist at all (a secrets manager plus IRSA).
base64 is not a lock: jsonpath gave ZmxvY2ktZHVtbXktdG9rZW4tbm90LWEtcmVhbC1zZWNyZXQ= and base64 -d gave floci-dummy-token-not-a-real-secret, with no key and no permission beyond get secret.
kubectl set env deployment/usms-enrolment --from=secret/usms-enrolment-secret rolled out a new ReplicaSet (the pod template changed). Difference from the lab text: this kubectl (v1.34-era) wrote one env entry per key with valueFrom.secretKeyRef, not an envFrom.secretRef, so envFrom lists only usms-app-config and describe shows the two keys under Environment as "set to the key ... in secret 'usms-enrolment-secret'". Same effect.
Inside the container: four APP_* and two ENROLMENT_* variables, the token in plain text. A Secret protects the value on its way to the pod, not inside it, and gives no confidentiality at rest unless etcd encryption (KMS envelope encryption on EKS) is configured.

## Step 18: roll out a change, then roll it back
ConfigMap APP_VERSION 1.0.0 -> 1.1.0 and applied: the running pods still answered 1.0.0 - a ConfigMap change does not restart pods.
kubectl annotate deployment ... config-revision: no rollout (it changes the Deployment's metadata, not the pod template); pods still 1.0.0. kubectl rollout restart (writes a timestamp into the pod template): new ReplicaSet, pods answered 1.1.0.
History: revisions 1, 2, 3 (rev 1 the original, rev 2 the Secret env change, rev 3 the restart), each a ReplicaSet with the old ones kept at 0.
Rollback (danger notice read: pod template reverts, gateway unaffected because it routes by Service name, reversible): rollout undo scaled revision 2's ReplicaSet back up and renumbered it revision 4 - nothing rebuilt. Pods still answered 1.1.0, because undo reverts the pod template, not the ConfigMap. kubectl warned that rollback does not update the last-applied-configuration annotation, so a later kubectl apply of the manifest could undo the rollback.
Restored the ConfigMap to 1.0.0 and restarted: pods answer 1.0.0; usms-enrolment is on revision 5, 2/2.
Your turn: kubectl set image deployment/usms-results results=nginx:1.27, then rollout undo. Peak during the roll: 3 pods (2 + 1 surge); the image returned to nginx:1.27-alpine; rollout history shows two revisions (2 and 3).
How it differed: with 2 replicas it did NOT differ in shape. The default strategy is maxSurge 25% / maxUnavailable 25%, and Kubernetes rounds maxSurge up (25% of 2 -> 1) and maxUnavailable down (25% of 2 -> 0), so it behaves exactly like usms-enrolment's explicit maxSurge 1 / maxUnavailable 0. The defaults would only allow a pod to go missing during a roll from 4 replicas upward.

## Step 19: three failures, diagnosed
1. Image that does not exist: the new pod went ErrImagePull then ImagePullBackOff (describe/events: "failed to resolve reference docker.io/library/nginx:this-tag-does-not-exist: not found"), while both old pods stayed Running and serving - the roll stopped at the first new pod. Fixed with rollout undo; back on nginx:1.27-alpine.
2. Pod that cannot be scheduled (cpu 64, memory 256Gi): Pending, FailedScheduling "0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory" (the lab expects 0/3 - this build has one node). Deleted.
3. Container that exits 1: CrashLoopBackOff, 2 restarts in 31 s; logs and logs --previous show "usms-crasher starting" and "fatal: no database configured"; Last State Terminated, Reason Error, Exit Code 1. Deleted.
End state: five pods Running, nothing left over.

## Step 20 - ECS and Kubernetes, compared with both running
Checked side by side (labs/lab-07-eks/evidence/lab-07-steps20-21.txt): ECS usms-enrolment-svc desired 2, running 2, usms-enrolment:2, one load balancer; EKS usms-enrolment 2/2, usms-results 2/2, usms-gateway 1/1, three ClusterIP Services.

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | A task definition revision (usms-enrolment:2), immutable, registered through the AWS API | The pod template inside a Deployment, written in a manifest and applied with kubectl |
| What keeps N copies alive? | The ECS service scheduler, against desiredCount | The ReplicaSet the Deployment owns, against spec.replicas |
| What gives it a stable name? | A load balancer (Lab 05) or Service Connect / Cloud Map; nothing by default | A Service: a ClusterIP plus a DNS name, usms-enrolment.usms.svc.cluster.local |
| How does another service find it? | Through the load balancer's DNS name (Lab 05), or a service discovery namespace | Cluster DNS (CoreDNS) resolves the Service name; kube-proxy spreads connections over the endpoints |
| What does a rolling update create? | A new deployment of the service, starting tasks from the new task definition revision | A new ReplicaSet, scaled up as the old one is scaled down |
| Where does rollback state live? | In the task definition revisions: you point the service back at :1 | In the old ReplicaSets kept at 0 (revisionHistoryLimit); rollout undo scales one back up |
| Which IAM role does the app code use? | The task role (usms-ecs-task-role), per task | Here the node role (usms-eks-node-role), shared by every pod on the node; properly, IRSA or Pod Identity per service account |
| What would I have to change to move to another cloud? | Almost everything: task definitions, services, roles and the load balancer are AWS APIs | The manifests move unchanged; the IAM roles, VPC, node groups, load balancer annotations and storage classes do not |

For USMS I would choose ECS on Fargate: three small HTTP services do not need Kubernetes' flexibility, and ECS leaves no nodes, CNI or control-plane versions to patch. I would revisit it only if USMS needed to run on more than one cloud or on campus, where Kubernetes' portable manifests become worth the operational cost.

## Step 21: IRSA
OIDC issuer: None (cluster.identity.oidc.issuer), so steps 1 and 2 of IRSA (publish the discovery document, register it as an IAM OIDC provider) cannot happen here, and therefore neither can 3 to 6. list-open-id-connect-providers answered with an empty list.
Created anyway: ServiceAccount usms-enrolment-sa in namespace usms (manifests/lab-07/60-serviceaccount.yaml). Of the six IRSA steps this build completed none of the AWS side; only the Kubernetes object the role would be bound to exists.
On real AWS: register the issuer once per cluster with create-open-id-connect-provider, write a role trusting that provider for sub system:serviceaccount:usms:usms-enrolment-sa, annotate the ServiceAccount with eks.amazonaws.com/role-arn, and only pods using it get 15-minute credentials. Until then, USMSStudentDataReadWrite on the node role reaches every pod on every node, including a compromised one.

## Step 22: persistence across a restart - FAILED for the Kubernetes half
Before (labs/lab-07-eks/evidence/lab-07-before-restart.txt): cluster ACTIVE 1.30, node group ACTIVE desired 2, Deployments 2/1/2, three Services.
floci-down.sh / floci-up.sh. Floci logged "Stopped k3s container for cluster usms-eks-cluster" on shutdown, and after start-up loaded the cluster and node group records from /app/data (eks-clusters.json, eks-nodegroups.json) - but no k3s container existed afterwards, running or stopped, and there was no k3s volume.
After (lab-07-after-restart.txt): the cluster was re-derived from list-clusters and the node group from list-nodegroups, both ACTIVE - the AWS half persisted. The Kubernetes half did not: kubectl got "connection to the server localhost:6500 was refused", and the namespace, Deployments, Services, ConfigMaps, Secret and ServiceAccount were gone, because k3s keeps them inside the container. The lab's diff printed "differences above", not PERSISTENCE PROVEN.
Floci limitation: Floci's EKS keeps the AWS records in hybrid storage but removes the k3s container on stop and does not recreate it on start, so an ACTIVE cluster record survives with nothing behind it. Real EKS's control plane (etcd) is managed by AWS and outlives anything you do on your side; there is no equivalent of this.
Side effect, as in Lab 05: the restart left all four Lab 3 instances stopped; started again with ec2 start-instances.

### Rebuild (labs/lab-07-eks/evidence/lab-07-rebuild.txt)
Because verification, configs/lab-07.env and Lab 08 need a working cluster, I deleted the node group and the cluster record (which pointed at nothing), recreated both from the same request bodies as usms-developer-role (identity restored afterwards), refreshed the kubeconfig (new k3s, new certificate authority; same endpoint, https://localhost:6500), and ran kubectl apply -f manifests/lab-07/. The numeric prefixes put the namespace first; every object came back in one command. The only step that had to be repeated by hand was Step 17's kubectl set env --from=secret, because it was imperative and lives in no manifest - the lesson of this rebuild. All three Deployments rolled out (2/2, 2/2, 1/1) and requests through the gateway reached usms-enrolment and usms-results again. The Services have new ClusterIPs (10.43.121.90, 10.43.80.200, 10.43.249.84); nothing needed changing, because the gateway uses names.
The rollout history from Step 18 was not recreated: the rebuilt Deployments start again from their manifests.

## Step 23: configs/lab-07.env
21 exports, all populated, every AWS value looked up: ARN, status ACTIVE, version 1.30, endpoint https://localhost:6500, _lb_ports_ 8081,8083, both role ARNs, both policy ARNs, cluster security group. The header records that the kubeconfig is ~/.kube/usms-lab07 and why the ports are 8081,8083.

## Section 8: verify-lab-07.sh
As the lab gives it: PASS=29 FAIL=1 - only the outputs/.gitkeep false positive (same as Labs 2, 4, 5 and 6).
Changes: git hygiene ignores outputs/.gitkeep; when KUBECONFIG is unset the script uses ~/.kube/usms-lab07; and a new check, "kubectl's server is usms-eks-cluster's endpoint", because "kubectl reaches an API server" passes for any cluster - with the default kubeconfig and the other module's cluster running, every Kubernetes check would have been testing the wrong cluster.
Result: PASS=31 FAIL=0. Negative test with KUBECONFIG=~/.kube/config (kind-dso202, stopped): the two API checks and the six Kubernetes checks after them fail, PASS=23 FAIL=8.
Cleanup script copied from the lab, passes bash -n, NOT run.

## Step 24: Git
manifests/lab-07/50-secret.yaml is committed deliberately: its two values are labelled dummies, and the lab keeps it as the example for this check. In any real repository it would be generated into outputs/ or not at all.

## Exercise 5 part 3: which of configs/lab-07.env's 21 variables Lab 08 needs
- USMS_EKS_CLUSTER - every aws eks call and update-kubeconfig in Lab 08 names the cluster.
- USMS_EKS_NODEGROUP - Lab 08 changes the node group's scaling from the AWS side (update-nodegroup-config).
- USMS_EKS_NAMESPACE - every kubectl command in Lab 08 works inside usms.
- USMS_EKS_ENDPOINT - to confirm kubectl points at this cluster (verify-lab-07.sh now checks it); it is https://localhost:6500 here, not :6443.
- USMS_EKS_LB_PORTS - Lab 08 reaches its LoadBalancer Service and Ingress on these host ports; here 8081,8083, so "8082" in Lab 08 means 8083.
- USMS_EKS_CLUSTER_STATUS - a quick check that the cluster is ACTIVE before starting; after a Floci restart it can read ACTIVE with no k3s behind it, so check kubectl too.
- USMS_EKS_NODE_ROLE_ARN - Lab 08's node scaling adds nodes that assume this role.
- USMS_K8S_DEPLOY_ENROLMENT - Lab 08 attaches the HorizontalPodAutoscaler to this Deployment.
- USMS_K8S_CPU_REQUEST - the HPA's utilisation is measured against this 50m; without a request it reads nothing.
- USMS_K8S_SVC_GATEWAY and USMS_K8S_DEPLOY_GATEWAY - Lab 08 turns the gateway Service into a LoadBalancer and puts an Ingress in front of it.
- USMS_K8S_MANIFEST_DIR - Lab 08 adds its manifests next to these and re-applies them after a restart (see Step 22).
Not needed by Lab 08: the cluster ARN, version, cluster role ARN, the two policy ARNs, the cluster security group, and the results Deployment and Service names - they describe what this lab built, and the CloudFormation lab is the one that re-declares them.

## Review questions

**1. ACTIVE cluster, every pod Pending.**
ACTIVE describes the control plane only - the API server, etcd and the scheduler that AWS runs - while pods run on the data plane, the nodes in my account, and a scheduler with no nodes that fit has nowhere to put them, so it leaves them Pending. Both are true at once because they are different halves of the system with different owners. Two configurations that produce it: a cluster with no node group (or a node group whose nodes never join, for example because the node role lacks eks:DescribeCluster or trusts the wrong principal), and pods whose requests exceed every node - Step 19's usms-toobig, Pending with "0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory". A nodeSelector or taint that no node matches does the same.

**2. Swapping the two trust policies.**
The cluster role would trust ec2.amazonaws.com and the node role eks.amazonaws.com. On real AWS, create-cluster (Step 8) calls sts:AssumeRole on the cluster role as eks.amazonaws.com and fails at once, because that principal is not trusted - you would notice at Step 8. If the cluster somehow existed, the nodes in Step 10 would fail to launch with an instance profile whose role EC2 cannot assume, so the node group would end CREATE_FAILED and kubectl get nodes in Step 11 would be empty. On Floci nothing is assumed or enforced (policies are stored, not evaluated), so both steps succeed and you would not notice at all - which is why Steps 6 and 7 check the trust policy by reading it.

**3. Readiness probe versus liveness probe.**
A readiness probe answers "should this pod receive traffic now?": failing it removes the pod from the Service's endpoints and nothing else. A liveness probe answers "is this container stuck?": failing it makes the kubelet kill and restart the container. Getting it backwards: a liveness probe on a dependency check (say, "can I reach the database?") restarts every pod in a loop during a database outage - which cannot help and turns a degraded service into a dead one - where a readiness probe would simply take them out of rotation until the database returned. In the other direction, Exercise 3 showed a readiness probe on a path the app does not serve: the pods ran forever, never Ready, and the Service had no endpoints, with nothing in the logs.

**4. After rollback the pod still said 1.1.0.**
rollout undo restores the previous pod template - the image, environment wiring, probes - by scaling an old ReplicaSet back up, but the ConfigMap is a separate object that the template only refers to by name, and it still held 1.1.0. For "it is not really a rollback": a release is everything that changed, and Kubernetes rolled back only the part stored in the Deployment, so the system ran a combination that never existed as a release. Against: it does exactly what it says - it rolls back the Deployment - and the fault is in treating the ConfigMap as unversioned. The practice that resolves it is versioning configuration with the workload: give each ConfigMap a new name per release (usms-app-config-v2, or a content hash, as Kustomize's configMapGenerator does) and reference it from the template, so the template change and the config change are the same revision and undo restores both.

**5. maxUnavailable 0 against the default, for two replicas.**
With two replicas they behaved identically in Step 18's "Your turn": the default 25% / 25% rounds maxSurge up to 1 and maxUnavailable down to 0, so both start one new pod, wait for it to be ready, then stop one old pod, peaking at 3. They differ from four replicas up, where the default lets one pod go missing during the roll. maxUnavailable 0 suits a service that must not lose capacity during a deploy, like enrolment in its busy week; the default suits something that can briefly run short and wants faster rolls with less extra capacity, like results or a batch API. Lab 04's ECS defaults (minimumHealthyPercent 100, maximumPercent 200) are the closer match to maxUnavailable 0: never fewer than desired, temporarily more.

**6. "A Secret is encrypted, so it's fine to commit the manifest."**
A Secret is base64-encoded, not encrypted: Step 17 decoded the token with base64 -d and needed nothing but get access. What it does provide is separation - the value is not in the image or the Deployment, it can be restricted by RBAC separately from ConfigMaps, and describe hides it. It provides no confidentiality in a Git repository, where a committed value is readable by anyone with the repository and stays in history after you delete it, and none at rest in etcd unless encryption is configured. On real EKS I would turn on KMS envelope encryption of Secrets, keep the value in AWS Secrets Manager and bring it in with the Secrets Store CSI driver or External Secrets, give pods AWS access through IRSA or Pod Identity instead of stored keys, and never commit a Secret manifest.

**7. ECS or Kubernetes for USMS.**
For USMS - a small team, one region, quiet for eight months and busy for two - I would choose ECS on Fargate. This lab made several things harder than Lab 04: two IAM roles and a node group to own instead of one task role; nodes to patch and versions to upgrade in two steps; a second API and tool (kubectl, its own kubeconfig and context); Secrets that need extra machinery to be safe; and, on this build, a control plane whose state did not survive a restart. Kubernetes did give me something ECS could not: one kubectl apply of a directory of portable manifests recreated the whole application on a new cluster in under a minute, and the same files would run on any conformant cluster - on campus or another cloud. For USMS that portability is not worth the operational load; for a team running many services across environments it would be.
