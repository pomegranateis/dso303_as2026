# Cloud Architecture Lab build (Task 3)

The production architecture, built in the [Cloud Architecture Lab](https://main.d35uam9e2t7o65.amplifyapp.com).

| File | Scenario it opens with |
|---|---|
| `exam-platform.cal.json` | Walkthrough 1 – `PUT /api/attempts/1234/answers` from *Student browser (walkthrough 1)* |
| `exam-platform-walkthrough-2.cal.json` | Walkthrough 2 – `POST /submissions/DSO303-A2/report.pdf` from *Student browser (walkthrough 2)* |
| `build_workspace.py` | Generates both: `python3 simulation/build_workspace.py` |

Both files contain the same diagram. The lab starts a request at the scenario's start node, and the two walkthroughs start at different clients: the exam goes through the API, while the upload goes straight to S3.

## What is in it

- **Containers:** the region, the VPC `10.20.0.0/16`, and six subnets. Public, private app and private data in **AZ-A and AZ-B**, each a /19, matching `infra/network.tf`. (The lab carves the VPC into equal /19s itself.)
- **Edge:** Route 53, WAF, CloudFront, ACM.
- **Regional:** S3 frontend, S3 uploads, API Gateway, Cognito.
- **In the VPC:**
  - an internet gateway and a NAT gateway per AZ;
  - in each AZ's app subnet: exam-api, submission-processor and auto-marker Lambda network interfaces, plus RDS Proxy;
  - RDS PostgreSQL **Multi-AZ** (primary AZ-A, synchronous standby AZ-B);
  - VPC endpoints.
- **Async:** uploads, marking and email queues, a dead-letter queue, the EventBridge bus, the notifier and SES.
- **Operations:** Secrets Manager, KMS, CloudWatch, SNS, CloudTrail, AWS Backup, GitHub Actions.
- **IAM:** every function, and RDS Proxy, carries **its own least-privilege IAM role** (the same permissions as the Terraform). The lab authorises every call against it.
- **Numbered connections** (`stepNumber`) are the walkthrough steps. **Task flow** draws them on the canvas.

## How to run it

1. **Load walkthrough 1:** Open the lab → **Export** → **Upload JSON** → `exam-platform.cal.json`.
2. **Simulate it:** **Simulate** → **Send Request**. The request runs Student → Route 53 → WAF → CloudFront → API Gateway (picks a healthy Lambda of the two registered) → exam-api Lambda AZ-A → RDS → **HTTP 200**.
3. **Fail an AZ:** **Failure Lab** → **AZ-A outage** → **Send Request**. API Gateway now selects **exam-api Lambda (AZ-B)**, and the database step is **"Multi-AZ Automated Database Failover"**, promoting the standby in AZ-B → **HTTP 200**. The Failure Lab bar summarises the impact (resources in AZ-A failed, dependants affected).
4. **Restore:** **Restore all**.
5. **Load walkthrough 2:** **Export** → **Upload JSON** → `exam-platform-walkthrough-2.cal.json` → **Send Request**. The request runs Student → S3 uploads (presigned POST, not through the API) → `sqs: send` to the uploads queue → Lambda event source mapping → submission-processor in AZ-A and AZ-B → **HTTP 202**.
   - **With AZ-A down, also HTTP 202:** the AZ-A consumer's copy is redriven to the dead-letter queue and the AZ-B consumer processes it.
   - **The tutor-notification half** (steps 4–8: EventBridge → email queue → notifier → SES → tutor) is drawn as numbered connections. The lab ends a request at the asynchronous boundary (the student gets 202 Accepted). The same half runs for real in the Floci deployment: the smoke test and the video show the tutor's email arriving.
6. **Analyze:** rated **Resilient**. Availability 100%, Fault Tolerance 100%, Security & Isolation 100%, **0 single points of failure**.

## Analyser findings that remain, and why

| Finding | Why it stays |
|---|---|
| Bottlenecks (2): "compute connects directly to a single relational database without an in-memory cache or RDS Proxy" | The rule counts compute nodes and looks only for ElastiCache, even though the design has RDS Proxy. At the exam peak the database load (~10 starts/s, ~100 small upserts/s) does not need a cache; adding one only to satisfy the scorer would misrepresent the design. Each Lambda also has a direct edge to RDS, because the lab's compute handler only executes SQL against `rds`/`aurora`/`dynamodb` nodes. |
| Configuration validity (5): "dependency-call execution is not modeled" on Lambda → RDS Proxy and RDS Proxy → Secrets Manager | The lab does not execute RDS Proxy dependency calls. The edges are kept because they are the real design (the proxy reads the secret and pools the connections). |
| Architecture risk: "dependency concentration" on the database | Inherent to one relational store. Mitigated by Multi-AZ, RDS Proxy, PITR and AWS Backup. |
