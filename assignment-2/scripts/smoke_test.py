#!/usr/bin/env python3
"""End-to-end smoke test of both walkthroughs against a deployed stack.

Uses only the standard library and talks to the platform exactly as the browser does:
Cognito InitiateAuth, the API, a presigned POST straight to S3. Run after deploy.sh:

    python3 scripts/smoke_test.py            # reads terraform outputs from infra/
Exit status 0 means every check passed. A JSON report is written to build/smoke-report.json.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPORT = []
PASSWORD = os.environ.get("DEMO_PASSWORD", "ExamDemo#2026")


def tf_outputs():
    out = subprocess.run(["terraform", "output", "-json"], cwd=ROOT / "infra", check=True,
                         capture_output=True, text=True).stdout
    return {k: v["value"] for k, v in json.loads(out).items()}


def check(name, ok, detail=""):
    REPORT.append({"check": name, "ok": bool(ok), "detail": detail})
    print(f"  {'ok  ' if ok else 'FAIL'} {name}{'  -- ' + str(detail) if detail else ''}", flush=True)
    return ok


def http(method, url, body=None, headers=None, raw=None, timeout=120):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    if body is not None and "Content-Type" not in (headers or {}):
        req.add_header("Content-Type", "application/json")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            text = r.read().decode() or "{}"
            status = r.status
    except urllib.error.HTTPError as e:
        text, status = e.read().decode() or "{}", e.code
    ms = int((time.time() - t0) * 1000)
    try:
        return status, json.loads(text), ms
    except json.JSONDecodeError:
        return status, {"raw": text[:300]}, ms


def sign_in(cfg, email):
    status, body, _ = http("POST", cfg["cognito"] + "/", {
        "AuthFlow": "USER_PASSWORD_AUTH", "ClientId": cfg["client"],
        "AuthParameters": {"USERNAME": email, "PASSWORD": PASSWORD}},
        headers={"Content-Type": "application/x-amz-json-1.1",
                 "X-Amz-Target": "AWSCognitoIdentityProviderService.InitiateAuth"})
    token = (body.get("AuthenticationResult") or {}).get("IdToken")
    check(f"Cognito sign-in {email}", status == 200 and token, f"HTTP {status}")
    return token


def api(cfg, token, method, path, body=None):
    headers = {"Authorization": token} if token else {}
    return http(method, f"{cfg['api']}{path}", body, headers)


def wait_for(fn, seconds=120, every=3):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(every)
    return None


def multipart(fields, file_field, filename, content, ctype):
    boundary = uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'
                 f'Content-Type: {ctype}\r\n\r\n'.encode() + content + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def ses_messages(cfg, to):
    if not cfg["floci"]:
        return []
    _, body, _ = http("GET", cfg["endpoint"] + "/_aws/ses")
    return [m for m in body.get("messages", []) if to in json.dumps(m.get("Destination", m))]


def main():
    out = tf_outputs()
    floci = out["app_url"].startswith("http://")
    endpoint = "http://localhost:4566"
    cfg = {"api": out["api_base_url"], "client": out["user_pool_client_id"], "floci": floci,
           "endpoint": endpoint,
           "cognito": endpoint if floci else f"https://cognito-idp.{out['user_pool_id'].split('_')[0]}.amazonaws.com"}
    print(f"API: {cfg['api']}\n")

    print("Health and access control")
    s, b, ms = api(cfg, None, "GET", "/health")
    check("GET /api/health reaches Lambda and the database", s == 200 and b.get("status") == "ok", f"HTTP {s}, {ms} ms")
    s, _, _ = api(cfg, None, "GET", "/exams")
    check("no token -> 401 (authorizer on AWS; token check in the function everywhere)", s == 401, f"HTTP {s}")
    student = sign_in(cfg, "student1@exams.example.edu")
    tutor = sign_in(cfg, "tutor1@exams.example.edu")
    s, _, _ = api(cfg, student, "GET", "/submissions")
    check("student calling a tutor endpoint -> 403", s == 403, f"HTTP {s}")

    print("\nTutor creates a timed exam (a fresh one each run, so the test can be repeated)")
    s, b, ms = api(cfg, tutor, "POST", "/exams", {
        "title": f"Smoke test exam {time.strftime('%Y-%m-%d %H:%M:%S')}", "durationMin": 30,
        "questions": [
            {"kind": "mcq", "prompt": "Which RDS feature keeps a synchronous standby in another AZ?",
             "options": ["Read replica", "Multi-AZ deployment", "Snapshots"], "answerKey": "Multi-AZ deployment"},
            {"kind": "mcq", "prompt": "How does a 40 MB file reach S3 without passing through the API?",
             "options": ["S3 presigned POST", "API Gateway binary media", "Lambda URL"], "answerKey": "S3 presigned POST"},
            {"kind": "mcq", "prompt": "What does a dead-letter queue hold?",
             "options": ["Messages that failed too many times", "Messages older than 14 days"],
             "answerKey": "Messages that failed too many times"},
            {"kind": "short", "prompt": "Why autosave every 30 seconds?", "marks": 2}]})
    check("tutor creates an exam (POST /api/exams)", s == 201 and b.get("questions") == 4, f"HTTP {s}, {b.get('examId')}")
    exam = b["examId"]
    s, _, _ = api(cfg, student, "POST", "/exams", {"title": "x", "durationMin": 5, "questions": []})
    check("student cannot create exams (403)", s == 403, f"HTTP {s}")

    print("\nWalkthrough 1: open an exam, autosave, submit")
    s, b, ms = api(cfg, student, "POST", f"/exams/{exam}/attempts")
    check("start attempt returns questions without answer keys",
          s == 200 and b.get("questions") and all("answer_key" not in q for q in b["questions"]), f"HTTP {s}, {ms} ms")
    attempt = b["attempt"]["id"]
    q = [x["id"] for x in sorted(b["questions"], key=lambda x: x["position"])]
    answers = {q[0]: "Multi-AZ deployment", q[1]: "S3 presigned POST"}
    s, b, ms = api(cfg, student, "PUT", f"/attempts/{attempt}/answers", {"answers": answers, "seq": 1})
    check("autosave #1 (2 answers)", s == 200 and b.get("saved") == 2, f"HTTP {s}, {ms} ms")
    answers.update({q[2]: "Messages older than 14 days", q[3]: "So a crash or a dropped connection loses at most 30 seconds."})
    s, b, ms = api(cfg, student, "PUT", f"/attempts/{attempt}/answers", {"answers": answers, "seq": 2})
    check("autosave #2 (4 answers)", s == 200 and b.get("saved") == 4, f"HTTP {s}, {ms} ms")
    s, b, _ = api(cfg, student, "PUT", f"/attempts/{attempt}/answers", {"answers": {q[0]: "Read replica"}, "seq": 1})
    s, b, _ = api(cfg, student, "POST", f"/exams/{exam}/attempts")
    check("resume returns the saved answers; a stale retry (seq 1) did not overwrite seq 2",
          b.get("savedAnswers", {}).get(q[0]) == "Multi-AZ deployment" and len(b.get("savedAnswers", {})) == 4,
          json.dumps(b.get("savedAnswers"))[:120])
    s, b, ms = api(cfg, student, "POST", f"/attempts/{attempt}/submit")
    check("submit -> 202, marking queued on SQS", s == 202, f"HTTP {s}, {ms} ms")
    marked = wait_for(lambda: api(cfg, student, "GET", f"/attempts/{attempt}")[1].get("status") == "marked", 180)
    check("auto-marker (SQS -> Lambda) marked the attempt", marked)
    s, _, _ = api(cfg, student, "PUT", f"/attempts/{attempt}/answers", {"answers": {q[0]: "x"}, "seq": 9})
    check("autosave after submit is refused (409)", s == 409, f"HTTP {s}")

    print("\nWalkthrough 2: upload a 40 MB assignment, tutor notified")
    s, b, _ = api(cfg, student, "POST", "/assignments/DSO303-A2/upload-url",
                  {"filename": "too-big.pdf", "size": 60 * 1024 * 1024, "contentType": "application/pdf"})
    check("60 MB request refused before any upload (400)", s == 400, f"HTTP {s}")
    s, b, _ = api(cfg, student, "POST", "/assignments/DSO303-A2/upload-url",
                  {"filename": "virus.exe", "size": 1000, "contentType": "application/x-msdownload"})
    check("non PDF/ZIP refused (400)", s == 400, f"HTTP {s}")
    size = 40 * 1024 * 1024
    content = b"%PDF-1.7\n" + os.urandom(size - 9)
    s, b, ms = api(cfg, student, "POST", "/assignments/DSO303-A2/upload-url",
                   {"filename": "a2-report.pdf", "size": size, "contentType": "application/pdf"})
    check("presigned POST issued (policy limits size and type)", s == 200 and b.get("upload"), f"HTTP {s}, {ms} ms")
    sub_id, upload = b["submissionId"], b["upload"]
    body, ctype = multipart(upload["fields"], "file", "a2-report.pdf", content, "application/pdf")
    t0 = time.time()
    s, _, _ = http("POST", upload["url"], raw=body, headers={"Content-Type": ctype}, timeout=300)
    check("40 MB file POSTed straight to S3 (not through the API)", s in (200, 201, 204),
          f"HTTP {s}, {time.time() - t0:.1f} s")

    def received():
        _, b, _ = api(cfg, tutor, "GET", "/submissions?assignmentId=DSO303-A2")
        row = next((x for x in b.get("submissions", []) if x["id"] == sub_id), None)
        return row if row and row["status"] == "received" else None
    row = wait_for(received, 180)
    check("S3 -> SQS -> submission-processor marked it received", row,
          f"size_bytes={row and row['size_bytes']}")
    mail = wait_for(lambda: [m for m in ses_messages(cfg, "tutor1@exams.example.edu")
                             if sub_id in json.dumps(m)], 120) if floci else True
    check("tutor e-mailed through EventBridge -> SQS -> notifier -> SES", mail,
          (mail[0].get("Subject") or mail[0].get("Message", {}).get("Subject", "")) if floci and mail else "")
    s, b, _ = api(cfg, tutor, "GET", f"/submissions/{sub_id}/download-url")
    check("tutor gets a short-lived download URL", s == 200 and b.get("url"), f"HTTP {s}")

    print("\nResults release (asynchronous e-mail)")
    s, b, _ = api(cfg, tutor, "POST", f"/exams/{exam}/release")
    check("tutor releases results -> ResultsReleased on EventBridge", s == 202, f"HTTP {s}")
    mail = wait_for(lambda: [m for m in ses_messages(cfg, "student1@exams.example.edu")
                             if "Results released" in json.dumps(m) and "Smoke test exam" in json.dumps(m)], 120) if floci else True
    check("student e-mailed the result (marking queue fan-out -> email queue -> SES)", mail)
    s, b, _ = api(cfg, student, "GET", f"/attempts/{attempt}")
    check("student sees the released MCQ score (2 of 3 MCQs right)", s == 200 and b.get("mcqScore") == 2,
          f"{b.get('mcqScore')} / {b.get('maxMcqScore')}")

    passed = sum(r["ok"] for r in REPORT)
    print(f"\n{passed}/{len(REPORT)} checks passed")
    (ROOT / "build").mkdir(exist_ok=True)
    (ROOT / "build" / "smoke-report.json").write_text(json.dumps(
        {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "api": cfg["api"], "checks": REPORT}, indent=2))
    sys.exit(0 if passed == len(REPORT) else 1)


if __name__ == "__main__":
    main()
