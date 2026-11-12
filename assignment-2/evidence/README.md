# Evidence

All screenshots were taken on 12 November 2026. The Cloud Architecture Lab ones use the drafts in [`../simulation/`](../simulation/); the app ones use the Floci deployment made by `scripts/deploy.sh`.

## Task 3 – Cloud Architecture Lab

| # | Screenshot | What it shows |
|---|---|---|
| 1 | [`cal-01-full-build.png`](cal-01-full-build.png) | The full build (the lab's own PNG export): the region, the VPC `10.20.0.0/16` with public, private app and private data subnets in AZ-A and AZ-B (/19 each), the edge, the async chain and operations. 38 services, 47 connections. |
| 2 | [`cal-02-walkthrough-1-http200.jpg`](cal-02-walkthrough-1-http200.jpg) | **Walkthrough 1** (`PUT /api/attempts/1234/answers`, the autosave). Student → Route 53 → WAF → CloudFront → API Gateway → exam-api Lambda (AZ-A) → RDS → **HTTP 200**, 11/11 steps. |
| 3a | [`cal-03a-az-a-outage-injected.jpg`](cal-03a-az-a-outage-injected.jpg) | **AZ failure injected.** Failure Lab → *AZ-A outage*: "5 resource(s) directly failed, 8 dependent(s) fully survive". |
| 3b | [`cal-03b-az-a-outage-http200.jpg`](cal-03b-az-a-outage-http200.jpg) | **The same request with AZ-A down.** Step 8 "Route to exam-api Lambda (ENI **AZ-B**)", step 9 "**Multi-AZ Automated Database Failover**" (the standby in AZ-B is promoted), step 10 **HTTP 200**. |
| 4 | [`cal-04-walkthrough-2-http202.jpg`](cal-04-walkthrough-2-http202.jpg) | **Walkthrough 2** (`POST /submissions/DSO303-A2/report.pdf`). Student → S3 uploads (presigned POST, not through the API) → uploads queue → Lambda event source mapping → submission-processor in AZ-A and AZ-B → **HTTP 202**. |
| 5 | [`cal-05-analyze-resilient.jpg`](cal-05-analyze-resilient.jpg) | **Analyze:** rated **Resilient**. Availability 100%, Resilience 95%, Fault Tolerance 100%, Scalability 80%. |
| 5b | [`cal-05b-no-single-points-of-failure.jpg`](cal-05b-no-single-points-of-failure.jpg) | **Analyze → Single Points of Failure:** "No single points of failure detected." The remaining findings are explained in [`../simulation/README.md`](../simulation/README.md). |

## Deployment (Floci)

| # | Evidence | What it shows |
|---|---|---|
| 6 | [`app-01-exam-autosave.jpg`](app-01-exam-autosave.jpg) | **Walkthrough 1, for real.** Student signed in through Cognito, started an exam the tutor had just created, answered, and the answers autosaved ("Saved at 12:04:49 PM (save #1)"). Activity log: `InitiateAuth` → `GET /api/exams` → `POST /api/exams/EX-F86CB0A0/attempts` → `PUT /api/attempts/…/answers` → 200. |
| 7 | [`app-02-upload-40mb-presigned-post.jpg`](app-02-upload-40mb-presigned-post.jpg) | **Walkthrough 2, the upload.** `POST /api/assignments/DSO303-A2/upload-url` → 200, then the 40.0 MB PDF went **straight to S3** with the presigned POST → 204 in 540 ms. |
| 8 | [`app-03-tutor-submissions.jpg`](app-03-tutor-submissions.jpg) | **The async step.** The tutor's submissions list: `dso303-a2-report.pdf`, 40.0 MB, status **received**, set by the submission-processor after S3 → SQS → Lambda checked the file. |
| 9 | [`app-04-ses-tutor-email.jpg`](app-04-ses-tutor-email.jpg) | **The tutor notified.** Floci's SES mailbox (`GET /_aws/ses`, filtered to this submission): "New submission: DSO303 Assignment 2" to the tutor, and the student's receipt, both sent within 2 s of the upload. |
| 10 | [`deployment/smoke-test-output.txt`](deployment/smoke-test-output.txt) | `scripts/smoke_test.py`: **24/24 checks**. Both walkthroughs, the 50 MB and file-type limits, the 401/403 checks, the stale-retry and submitted-exam guards, and the results release by email. ([`smoke-report.json`](deployment/smoke-report.json) is the same run as JSON.) |
| 11 | [`deployment/deploy-from-scratch.txt`](deployment/deploy-from-scratch.txt) | `destroy.sh` followed by `deploy.sh` on an empty Floci: **147 resources added**, and the schema and seed data created (6 tables). Evidence 6–10 come from this deployment. |
| 12 | [`deployment/database-multi-az-and-subnets.txt`](deployment/database-multi-az-and-subnets.txt) | The database is `MultiAZ: true`, and its subnet group spans both AZs. All six subnets are listed: public, app and data in each AZ. |
| 13 | [`deployment/plan-after-apply.txt`](deployment/plan-after-apply.txt) | `terraform plan` right after an apply: 0 to add, 0 to destroy. The 39 in-place updates are attributes that Floci accepts but does not return (see "Floci differences" in the main README). |
