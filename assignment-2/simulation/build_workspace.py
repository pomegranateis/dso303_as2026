#!/usr/bin/env python3
"""Generate the Cloud Architecture Lab draft for the exam platform.

    python3 simulation/build_workspace.py   ->  simulation/exam-platform.cal.json

Import it in the Cloud Architecture Lab (https://main.d35uam9e2t7o65.amplifyapp.com)
with Export -> Upload JSON. The format is the lab's own ("aws-architecture-lab",
version 2). Positions are absolute canvas coordinates.

How the lab simulates (learned from its engine, so the model is built to match):
- a request starts at the scenario's start node and follows "request path" edges;
- a compute node calls a database (rds/aurora/dynamodb) when one is its first
  connection, otherwise it enqueues to a connected SQS queue;
- every call from a compute node is authorised against the node's IAM role, using
  the target's resourceArn (or arn:aws:<service>:::<node id>), so each function
  carries its own least-privilege role here, as it does in the Terraform;
- an AZ outage fails every node whose az is that AZ; a database marked multiAz fails
  over to its standby instead of failing the request.
"""
import json
from pathlib import Path

OUT = Path(__file__).with_name("exam-platform.cal.json")
ACCT, REGION = "111122223333", "ap-south-1"

nodes, edges = [], []
CATEGORY = {
    "user": "Client / Ingress", "route53": "Networking & Content Delivery", "cloudfront": "Networking & Content Delivery",
    "waf": "Security, Identity & Compliance", "acm": "Security, Identity & Compliance", "s3": "Storage",
    "cognito": "Security, Identity & Compliance", "api_gateway": "Networking & Content Delivery", "lambda": "Compute",
    "internet_gateway": "Networking & Content Delivery", "nat_gateway": "Networking & Content Delivery",
    "rds": "Databases", "rds_proxy": "Databases", "sqs": "Integration & Messaging", "sqs_dlq": "Integration & Messaging",
    "eventbridge": "Integration & Messaging", "ses": "Business Applications", "sns": "Integration & Messaging",
    "secrets_manager": "Security, Identity & Compliance", "kms": "Security, Identity & Compliance",
    "cloudwatch": "Management & Governance", "cloudtrail": "Management & Governance", "backup": "Storage",
    "privatelink": "Networking & Content Delivery", "github": "Third-Party & External",
}

ARN = {
    "uploads": "arn:aws:s3:::exam-uploads",
    "site": "arn:aws:s3:::exam-frontend",
    "q-uploads": f"arn:aws:sqs:{REGION}:{ACCT}:exam-uploads-queue",
    "q-marking": f"arn:aws:sqs:{REGION}:{ACCT}:exam-marking-queue",
    "q-email": f"arn:aws:sqs:{REGION}:{ACCT}:exam-email-queue",
    "dlq": f"arn:aws:sqs:{REGION}:{ACCT}:exam-uploads-dlq",
    "bus": f"arn:aws:events:{REGION}:{ACCT}:event-bus/exam-events",
    "ses": f"arn:aws:ses:{REGION}:{ACCT}:identity/no-reply@exams.example.edu",
    "secrets": f"arn:aws:secretsmanager:{REGION}:{ACCT}:secret:exam/db/master",
    "kms": f"arn:aws:kms:{REGION}:{ACCT}:key/exam-data",
    "db": f"arn:aws:rds:{REGION}:{ACCT}:db:exam-db",
    "cw": f"arn:aws:cloudwatch:{REGION}:{ACCT}:*",
}


def boundary(id_, label, btype, x, y, w, h, **extra):
    nodes.append({"id": id_, "type": "boundaryNode", "position": {"x": x, "y": y},
                  "style": {"width": w, "height": h},
                  "data": {"label": label, "boundaryType": btype, "width": w, "height": h, **extra}})


def service(id_, svc, label, x, y, az="Edge / Global", subnet="global", multi_az=False, notes="", role=None, **cfg):
    if id_ in ARN:
        cfg["resourceArn"] = ARN[id_]
    data = {"serviceId": svc, "label": label, "category": CATEGORY[svc], "health": "healthy",
            "az": az, "subnet": subnet, "replicas": 1, "multiAz": multi_az, "notes": notes, "customConfig": cfg}
    if role:
        data["iamRole"] = role
    nodes.append({"id": id_, "type": "serviceNode", "position": {"x": x, "y": y}, "data": data})


def role(name, principal, *statements):
    return {"id": name,
            "trustPolicy": {"id": f"{name}-trust", "kind": "trust", "statements": [
                {"effect": "Allow", "actions": ["sts:AssumeRole"], "principals": [principal], "resources": []}]},
            "identityPolicies": [{"id": f"{name}-least-privilege", "kind": "identity", "statements": [
                {"effect": "Allow", "actions": acts, "resources": res} for acts, res in statements]}]}


ACCEPTS = {"route53": "DNS", "sqs": "Message", "sqs_dlq": "Message", "eventbridge": "Event", "rds": "SQL",
           "rds_proxy": "SQL"}


def link(src, dst, protocol=None, dependency=False, asynchronous=False, critical=True, step=None, relationship=None):
    svc = lambda i: next(n["data"]["serviceId"] for n in nodes if n["id"] == i)
    # what the target accepts; anything a queue delivers is a Message
    protocol = protocol or ("Message" if svc(src) in ("sqs", "sqs_dlq") else ACCEPTS.get(svc(dst), "HTTPS"))
    data = {"protocol": protocol, "interactionType": "asynchronous" if asynchronous else "synchronous",
            "isCriticalDependency": critical, "timeoutMs": 1500}
    if relationship:
        data["relationship"] = relationship  # e.g. "manages": control-plane, not a request hop
    elif dependency:
        data["traversal"] = "dependency"
    if step:
        data["stepNumber"] = step  # numbered walkthrough step: the lab follows (and draws) them in order
    edges.append({"id": f"{src}-{dst}", "source": src, "target": dst, "type": "custom", "data": data})


DB_ACCESS = (["rds-db:connect"], [ARN["db"]])
SECRET = (["secretsmanager:GetSecretValue"], [ARN["secrets"]])
METRICS = (["cloudwatch:PutMetricData", "logs:CreateLogStream", "logs:PutLogEvents"], ["*"])
API_ROLE = role("exam-exam-api-role", "lambda.amazonaws.com", DB_ACCESS, SECRET, METRICS,
                (["sqs:SendMessage"], [ARN["q-marking"]]),
                (["events:PutEvents"], [ARN["bus"]]),
                (["s3:PutObject", "s3:GetObject"], [ARN["uploads"] + "/submissions/*"]))
PROC_ROLE = role("exam-submission-processor-role", "lambda.amazonaws.com", DB_ACCESS, SECRET, METRICS,
                 (["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], [ARN["q-uploads"]]),
                 (["s3:GetObject"], [ARN["uploads"] + "/submissions/*"]),
                 (["events:PutEvents"], [ARN["bus"]]))
MARKER_ROLE = role("exam-auto-marker-role", "lambda.amazonaws.com", DB_ACCESS, SECRET, METRICS,
                   (["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], [ARN["q-marking"]]),
                   (["sqs:SendMessage"], [ARN["q-email"]]))
NOTIFIER_ROLE = role("exam-notifier-role", "lambda.amazonaws.com", METRICS,
                     (["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], [ARN["q-email"]]),
                     (["ses:SendEmail"], [ARN["ses"]]))
PROXY_ROLE = role("exam-rds-proxy-role", "rds.amazonaws.com", SECRET, (["kms:Decrypt"], [ARN["kms"]]))

# ------------------------------------------------------------------ containers
boundary("region", "AWS Region · ap-south-1 (Mumbai)", "region", 560, 0, 2700, 1560)
boundary("vpc", "exam-vpc · 10.20.0.0/16 · two Availability Zones", "vpc", 600, 120, 1300, 1400, cidr="10.20.0.0/16")
y0 = 220
for key, btype, title, height in (("public", "public_subnet", "Public", 230), ("app", "private_subnet", "Private app", 470),
                                  ("data", "private_subnet", "Private data", 330)):
    for az, col, x in (("AZ-A", "a", 630), ("AZ-B", "b", 1270)):
        idx = {"public": 0, "app": 2, "data": 4}[key] + (0 if col == "a" else 1)
        cidr = f"10.20.{idx * 32}.0/19"   # same /19s as infra/network.tf (and as the lab's own carving)
        boundary(f"{key}-{col}", f"{title} {col.upper()} · {az}", btype, x, y0, 600, height, az=az, cidr=cidr)
    y0 += height + 30

# ------------------------------------------------------------------ users and edge (global)
service("student", "user", "Student browser (walkthrough 1: exam + autosave)", 20, 380,
        notes="Start node for walkthrough 1: opens the exam and autosaves every 30 s")
service("uploader", "user", "Student browser (walkthrough 2: 40 MB upload)", 20, 760,
        notes="Start node for walkthrough 2: POSTs the file straight to S3 with a presigned form")
service("tutor", "user", "Tutor (receives the e-mail)", 20, 1080, notes="Notified by SES; downloads via a presigned GET")
service("route53", "route53", "Route 53 · exams.<university>", 230, 160)
service("waf", "waf", "AWS WAF · managed rules + rate limit", 230, 380)
service("cloudfront", "cloudfront", "CloudFront · / -> S3, /api/* -> API", 230, 600)
service("acm", "acm", "ACM certificate (us-east-1)", 230, 820)
service("github", "github", "GitHub Actions · terraform apply on push to main", 20, 1320)

# ------------------------------------------------------------------ regional services outside the VPC
service("site", "s3", "S3 frontend (private, OAC)", 380, 120)
service("apigw", "api_gateway", "API Gateway REST · Cognito authorizer", 380, 600)
service("cognito", "cognito", "Cognito · students | tutors | admins", 380, 1050)
service("uploads", "s3", "S3 uploads · SSE-KMS · IA->Glacier->expire 5 y", 1960, 140,
        versioning=True, encryption="SSE-KMS",
        lifecycle="STANDARD_IA 30d, GLACIER_IR 180d, DEEP_ARCHIVE 365d, expire 1830d")

# ------------------------------------------------------------------ inside the VPC
service("igw", "internet_gateway", "Internet gateway", 1180, 140)
service("nat-a", "nat_gateway", "NAT gateway A", 830, 280, az="AZ-A", subnet="public")
service("nat-b", "nat_gateway", "NAT gateway B", 1470, 280, az="AZ-B", subnet="public")
service("api-a", "lambda", "exam-api Lambda (ENI AZ-A)", 680, 540, az="AZ-A", subnet="private", role=API_ROLE)
service("api-b", "lambda", "exam-api Lambda (ENI AZ-B)", 1320, 540, az="AZ-B", subnet="private", role=API_ROLE)
service("proc-a", "lambda", "submission-processor (ENI AZ-A)", 980, 540, az="AZ-A", subnet="private", role=PROC_ROLE)
service("proc-b", "lambda", "submission-processor (ENI AZ-B)", 1620, 540, az="AZ-B", subnet="private", role=PROC_ROLE)
service("marker-a", "lambda", "auto-marker (ENI AZ-A)", 980, 760, az="AZ-A", subnet="private", role=MARKER_ROLE)
service("marker-b", "lambda", "auto-marker (ENI AZ-B)", 1620, 760, az="AZ-B", subnet="private", role=MARKER_ROLE)
service("proxy", "rds_proxy", "RDS Proxy (app subnets A + B)", 680, 760, az="Multi-AZ", subnet="private",
        multi_az=True, role=PROXY_ROLE)
service("endpoints", "privatelink", "VPC endpoints · SQS, Secrets, EventBridge, KMS", 1320, 760, az="Multi-AZ",
        subnet="private", multi_az=True, endpointService="sqs",
        services=["sqs", "secretsmanager", "events", "kms"])
service("db", "rds", "RDS PostgreSQL Multi-AZ · primary AZ-A, sync standby AZ-B", 830, 1100, az="AZ-A",
        subnet="private", multi_az=True, engine="postgres16", backupRetentionDays=35, encrypted=True)
service("db-standby", "rds", "RDS standby (synchronous replica of the Multi-AZ instance)", 1470, 1100, az="AZ-B",
        subnet="private", multi_az=True, notes="Same Multi-AZ instance; promoted automatically if AZ-A fails")

# ------------------------------------------------------------------ asynchronous processing
service("q-uploads", "sqs", "uploads queue (+DLQ)", 2200, 140)
service("bus", "eventbridge", "EventBridge bus · SubmissionReceived, ResultsReleased", 2440, 140)
service("q-email", "sqs", "email queue (+DLQ)", 2680, 140)
service("notifier", "lambda", "notifier Lambda (outside the VPC)", 2680, 360, az="Multi-AZ", multi_az=True,
        role=NOTIFIER_ROLE)
service("ses", "ses", "Amazon SES", 2920, 360)
service("q-marking", "sqs", "marking queue (+DLQ)", 2200, 360)
service("dlq", "sqs_dlq", "Dead-letter queues (alarmed)", 2440, 360)

# ------------------------------------------------------------------ security and operations
service("secrets", "secrets_manager", "Secrets Manager · DB credentials", 1960, 620)
service("kms", "kms", "KMS customer key", 2200, 620)
service("cw", "cloudwatch", "CloudWatch · logs, alarms, dashboard", 2440, 620)
service("sns", "sns", "SNS ops alerts", 2680, 620)
service("trail", "cloudtrail", "CloudTrail audit", 1960, 860)
service("backup", "backup", "AWS Backup · daily 35 d, monthly 5 y", 2200, 860)

# ------------------------------------------------------------------ walkthrough 1: open exam, autosave
# Numbered steps (stepNumber) are the walkthrough; the lab follows them in order.
link("student", "route53", step=1)
link("route53", "waf", step=2)
link("waf", "cloudfront", step=3)
link("cloudfront", "apigw", step=4)      # /api/* is forwarded, never cached
link("cloudfront", "site")               # the app shell itself is served from the edge cache
link("apigw", "cognito", dependency=True)
link("apigw", "api-a", step=5)
link("apigw", "api-b", step=5)
for fn in ("api-a", "api-b"):
    link(fn, "db", protocol="SQL", step=6)                            # autosave: upsert the answers
    link(fn, "q-marking", asynchronous=True, dependency=True, critical=False)  # submit: queue the marking
    link(fn, "proxy", protocol="SQL", dependency=True, critical=False)
    link(fn, "cw", dependency=True, critical=False)
link("proxy", "db", relationship="manages")  # the DB is the proxy's registered target
link("proxy", "secrets", dependency=True)
link("secrets", "kms", dependency=True)

# ------------------------------------------------------------------ walkthrough 2: 40 MB upload, tutor notified
link("uploader", "uploads", step=1)                 # presigned POST, straight to S3 (not through the API)
link("uploads", "q-uploads", asynchronous=True, step=2)
link("q-uploads", "proc-a", asynchronous=True, step=3)
link("q-uploads", "proc-b", asynchronous=True, step=3)
link("q-uploads", "dlq", asynchronous=True, critical=False)
for fn in ("proc-a", "proc-b"):
    link(fn, "bus", asynchronous=True, step=4)      # SubmissionReceived
    link(fn, "db", protocol="SQL", dependency=True)  # mark the submission received
link("bus", "q-email", asynchronous=True, step=5)
link("bus", "q-marking", asynchronous=True, critical=False)   # ResultsReleased fan-out
link("q-email", "notifier", asynchronous=True, step=6)
link("notifier", "ses", step=7)
link("ses", "tutor", asynchronous=True, step=8)
link("q-marking", "marker-a", asynchronous=True)
link("q-marking", "marker-b", asynchronous=True)
for fn in ("marker-a", "marker-b"):
    link(fn, "db", protocol="SQL", dependency=True)
    link(fn, "q-email", asynchronous=True, critical=False)

# ------------------------------------------------------------------ supporting
link("nat-a", "igw", critical=False)
link("nat-b", "igw", critical=False)
link("cw", "sns", dependency=True, critical=False)
link("backup", "db", relationship="manages", critical=False)
link("github", "apigw", relationship="manages", critical=False)  # the pipeline deploys it
link("cloudfront", "acm", dependency=True, critical=False)
link("db", "db-standby", protocol="Replication", critical=False)  # synchronous Multi-AZ replication
link("trail", "uploads", dependency=True, critical=False)

state = {
    "draftName": "Online exam platform (DSO303 Assignment 2)",
    "nodes": nodes,
    "edges": edges,
    "scenario": {"id": "walkthrough-1", "name": "Walkthrough 1 - open exam and autosave", "method": "PUT",
                 "path": "/api/attempts/1234/answers", "startNodeId": "student", "trafficLevel": "normal"},
    "activeFailures": [],
    "appMode": "design",
    "selectedNodeId": None,
    "selectedEdgeId": None,
    "activeChallengeId": None,
    "challengeResult": None,
    "playbackSpeed": 1,
    "highlightTaskFlow": False,
    "showNaclSideColumn": False,
    "activeStepIndex": None,
    "viewport": {"x": 40, "y": 40, "zoom": 0.45},
    "simulationResult": None,
    "activeLabReference": None,
}
# Two drafts, one diagram: the lab starts a request at the scenario's start node, and the
# two walkthroughs start at different clients.
SCENARIOS = {
    "exam-platform.cal.json": {"id": "walkthrough-1", "name": "Walkthrough 1 - open exam and autosave",
                               "method": "PUT", "path": "/api/attempts/1234/answers",
                               "startNodeId": "student", "trafficLevel": "normal"},
    "exam-platform-walkthrough-2.cal.json": {"id": "walkthrough-2", "name": "Walkthrough 2 - 40 MB upload, tutor notified",
                                             "method": "POST", "path": "/submissions/DSO303-A2/report.pdf",
                                             "startNodeId": "uploader", "trafficLevel": "normal"},
}
for filename, scenario in SCENARIOS.items():
    state = {**state, "scenario": scenario,
             "draftName": f"Online exam platform - {scenario['name']}"}
    doc = {"format": "aws-architecture-lab", "version": 2, "applicationRelease": None,
           "savedAt": "2026-11-12T00:00:00.000Z", "state": state}
    OUT.with_name(filename).write_text(json.dumps(doc, indent=2))
print(f"wrote {', '.join(SCENARIOS)}: {sum(n['type'] == 'serviceNode' for n in nodes)} services, "
      f"{sum(n['type'] == 'boundaryNode' for n in nodes)} containers, {len(edges)} connections")
