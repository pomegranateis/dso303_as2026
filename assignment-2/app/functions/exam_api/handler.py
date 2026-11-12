"""Exam platform API (API Gateway REST, Lambda proxy integration).

Tutors:
  POST /exams                        create a timed exam (MCQ + short answer)

Walkthrough 1 - open an exam and autosave:
  POST /exams/{examId}/attempts      start or resume an attempt, return questions (no answer keys)
  PUT  /attempts/{attemptId}/answers autosave (idempotent upsert, rejected after the deadline)
  POST /attempts/{attemptId}/submit  close the attempt and queue it for auto-marking (SQS)
Walkthrough 2 - upload an assignment:
  POST /assignments/{id}/upload-url  presigned S3 POST, max 50 MB, PDF or ZIP only
  GET  /submissions                  tutor: submissions and their status
  GET  /submissions/{id}/download-url tutor: short-lived presigned GET
Results:
  POST /exams/{examId}/release       tutor: publish a ResultsReleased event (EventBridge)
  GET  /attempts/{attemptId}         student: status, and the score once released
"""
import datetime
import json
import os
import re
import uuid

import boto3
from botocore.config import Config

import db
from web import CORS, HttpError, body_json, caller, require, respond

MAX_UPLOAD_BYTES = 50 * 1024 * 1024
ALLOWED_TYPES = {"application/pdf": ".pdf", "application/zip": ".zip", "application/x-zip-compressed": ".zip"}
GRACE_SECONDS = 30  # an autosave in flight when the timer hits zero still counts

_sqs = boto3.client("sqs")
_events = boto3.client("events")
# Presigned URLs are signed for the host the browser will use. On Floci the Lambda reaches
# S3 at http://floci:4566, which a browser cannot resolve, so PUBLIC_S3_ENDPOINT names the
# host-side address; on AWS it is unset and boto3 signs for the regional S3 endpoint.
_s3_public = boto3.client(
    "s3",
    endpoint_url=os.environ.get("PUBLIC_S3_ENDPOINT") or None,
    config=Config(signature_version="s3v4", s3={"addressing_style": "path" if os.environ.get("PUBLIC_S3_ENDPOINT") else "auto"}),
)


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def _uuid(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError):
        raise HttpError(404, "not found")


# ---------------------------------------------------------------- exams (walkthrough 1)

def list_exams(user, _event, _params):
    rows = db.run("select id, title, duration_min, opens_at, closes_at, released from exams order by id")
    if "students" in user["groups"]:
        mine = {r["exam_id"]: r for r in db.run(
            "select exam_id, id, status from attempts where student_id = :s", s=user["id"])}
        for r in rows:
            a = mine.get(r["id"])
            r["attempt"] = {"id": a["id"], "status": a["status"]} if a else None
    return 200, {"exams": rows}


def create_exam(user, event, _params):
    """Tutor creates a timed exam: MCQs (auto-marked) and short answers (marked by hand)."""
    require(user, "tutors")
    body = body_json(event)
    title = str(body.get("title") or "").strip()[:200]
    duration = int(body.get("durationMin") or 0)
    questions = body.get("questions") or []
    if not title or not 1 <= duration <= 300:
        raise HttpError(400, "an exam needs a title and a duration of 1-300 minutes")
    if not isinstance(questions, list) or not 1 <= len(questions) <= 100:
        raise HttpError(400, "an exam needs 1-100 questions")
    for q in questions:
        options = q.get("options") or []
        if q.get("kind") == "mcq" and (len(options) < 2 or q.get("answerKey") not in options):
            raise HttpError(400, f"MCQ '{str(q.get('prompt'))[:40]}' needs 2+ options and an answer key among them")
        if q.get("kind") not in ("mcq", "short") or not str(q.get("prompt") or "").strip():
            raise HttpError(400, "each question needs kind mcq|short and a prompt")
    exam_id = "EX-" + uuid.uuid4().hex[:8].upper()
    opens = _now()
    db.run("""insert into exams (id, title, duration_min, opens_at, closes_at, tutor_email)
              values (:i, :t, :d, :o, :c, :m)""",
           i=exam_id, t=title, d=duration, o=opens, c=opens + datetime.timedelta(days=int(body.get("openDays") or 7)),
           m=user["email"])
    for pos, q in enumerate(questions, start=1):
        db.run("""insert into questions (id, exam_id, position, kind, prompt, options, answer_key, marks)
                  values (:i, :e, :p, :k, :q, cast(:o as jsonb), :a, :m)""",
               i=f"{exam_id}-Q{pos}", e=exam_id, p=pos, k=q["kind"], q=str(q["prompt"])[:2000],
               o=json.dumps(q.get("options")) if q["kind"] == "mcq" else None,
               a=q.get("answerKey") if q["kind"] == "mcq" else None, m=int(q.get("marks") or 1))
    return 201, {"examId": exam_id, "title": title, "questions": len(questions)}


def start_attempt(user, _event, params):
    require(user, "students")
    exam = db.one("select * from exams where id = :e", e=params["examId"])
    if not exam:
        raise HttpError(404, "no such exam")
    now = _now()
    if not exam["opens_at"] <= now <= exam["closes_at"]:
        raise HttpError(409, "this exam is not open")
    attempt = db.one("select * from attempts where exam_id = :e and student_id = :s", e=exam["id"], s=user["id"])
    if attempt is None:
        attempt = db.one(
            """insert into attempts (id, exam_id, student_id, student_email, started_at, deadline)
               values (cast(:id as uuid), :e, :s, :m, :t, :d)
               on conflict (exam_id, student_id) do update set exam_id = excluded.exam_id
               returning *""",
            id=str(uuid.uuid4()), e=exam["id"], s=user["id"], m=user["email"], t=now,
            d=now + datetime.timedelta(minutes=exam["duration_min"]))
    questions = db.run(
        "select id, position, kind, prompt, options, marks from questions where exam_id = :e order by position",
        e=exam["id"])
    saved = {r["question_id"]: r["value"] for r in db.run(
        "select question_id, value from answers where attempt_id = cast(:a as uuid)", a=str(attempt["id"]))}
    for q in questions:
        if isinstance(q["options"], str):
            q["options"] = json.loads(q["options"])
    return 200, {
        "attempt": {"id": attempt["id"], "status": attempt["status"], "deadline": attempt["deadline"],
                    "serverTime": now},
        "exam": {"id": exam["id"], "title": exam["title"], "durationMin": exam["duration_min"]},
        "questions": questions,
        "savedAnswers": saved,
    }


def _own_attempt(user, attempt_id):
    attempt = db.one("select * from attempts where id = cast(:a as uuid)", a=_uuid(attempt_id))
    if not attempt or attempt["student_id"] != user["id"]:
        raise HttpError(404, "no such attempt")
    return attempt


def autosave(user, event, params):
    require(user, "students")
    attempt = _own_attempt(user, params["attemptId"])
    now = _now()
    if attempt["status"] != "in_progress":
        raise HttpError(409, "this attempt is already submitted")
    if now > attempt["deadline"] + datetime.timedelta(seconds=GRACE_SECONDS):
        raise HttpError(409, "time is up; answers after the deadline are not accepted")
    body = body_json(event)
    answers = body.get("answers") or {}
    seq = int(body.get("seq") or 0)
    if not isinstance(answers, dict) or len(answers) > 200:
        raise HttpError(400, "answers must be an object of questionId -> value")
    for qid, value in answers.items():
        # Idempotent upsert; a stale retry (lower client sequence) never overwrites a newer save.
        db.run(
            """insert into answers (attempt_id, question_id, value, client_seq, saved_at)
               values (cast(:a as uuid), :q, :v, :n, :t)
               on conflict (attempt_id, question_id) do update
                 set value = excluded.value, client_seq = excluded.client_seq, saved_at = excluded.saved_at
                 where answers.client_seq <= excluded.client_seq""",
            a=str(attempt["id"]), q=str(qid)[:64], v=None if value is None else str(value)[:5000], n=seq, t=now)
    return 200, {"saved": len(answers), "seq": seq, "savedAt": now,
                 "secondsLeft": max(0, int((attempt["deadline"] - now).total_seconds()))}


def submit(user, _event, params):
    require(user, "students")
    attempt = _own_attempt(user, params["attemptId"])
    if attempt["status"] == "in_progress":
        db.run("update attempts set status = 'submitted', submitted_at = :t where id = cast(:a as uuid)",
               t=_now(), a=str(attempt["id"]))
        _sqs.send_message(QueueUrl=os.environ["MARKING_QUEUE_URL"],
                          MessageBody=json.dumps({"type": "mark", "attemptId": str(attempt["id"])}))
    return 202, {"attemptId": attempt["id"], "status": "submitted", "marking": "queued"}


def get_attempt(user, _event, params):
    attempt = _own_attempt(user, params["attemptId"])
    exam = db.one("select released from exams where id = :e", e=attempt["exam_id"])
    out = {"id": attempt["id"], "examId": attempt["exam_id"], "status": attempt["status"],
           "submittedAt": attempt["submitted_at"]}
    if exam and exam["released"]:
        out.update(mcqScore=attempt["mcq_score"], maxMcqScore=attempt["max_mcq_score"],
                   pendingShortAnswers=attempt["pending_short"])
    return 200, out


def release(user, _event, params):
    require(user, "tutors")
    exam = db.one("update exams set released = true, released_at = :t where id = :e returning id, title",
                  t=_now(), e=params["examId"])
    if not exam:
        raise HttpError(404, "no such exam")
    _events.put_events(Entries=[{
        "EventBusName": os.environ["EVENT_BUS_NAME"], "Source": "exam-platform.api",
        "DetailType": "ResultsReleased",
        "Detail": json.dumps({"examId": exam["id"], "title": exam["title"], "releasedBy": user["email"]}),
    }])
    return 202, {"examId": exam["id"], "released": True, "emails": "queued"}


# ---------------------------------------------------------------- uploads (walkthrough 2)

def upload_url(user, event, params):
    require(user, "students")
    assignment = db.one("select * from assignments where id = :i", i=params["assignmentId"])
    if not assignment:
        raise HttpError(404, "no such assignment")
    body = body_json(event)
    filename = re.sub(r"[^A-Za-z0-9._-]", "_", str(body.get("filename") or ""))[:120]
    size = int(body.get("size") or 0)
    ctype = str(body.get("contentType") or "")
    if ctype not in ALLOWED_TYPES or not filename.lower().endswith(ALLOWED_TYPES[ctype]):
        raise HttpError(400, "only PDF or ZIP files are accepted")
    if not 0 < size <= MAX_UPLOAD_BYTES:
        raise HttpError(400, "files must be between 1 byte and 50 MB")
    sub_id = str(uuid.uuid4())
    key = f"submissions/{assignment['id']}/{user['id']}/{sub_id}/{filename}"
    db.run("""insert into submissions (id, assignment_id, student_id, student_email, filename, s3_key,
                                       declared_bytes, content_type)
              values (cast(:i as uuid), :a, :s, :m, :f, :k, :b, :c)""",
           i=sub_id, a=assignment["id"], s=user["id"], m=user["email"], f=filename, k=key, b=size, c=ctype)
    post = _s3_public.generate_presigned_post(
        Bucket=os.environ["UPLOAD_BUCKET"], Key=key,
        Fields={"Content-Type": ctype},
        Conditions=[{"Content-Type": ctype}, ["content-length-range", 1, MAX_UPLOAD_BYTES]],
        ExpiresIn=900)
    return 200, {"submissionId": sub_id, "upload": post, "maxBytes": MAX_UPLOAD_BYTES, "expiresInSeconds": 900}


def list_submissions(user, event, _params):
    require(user, "tutors")
    q = (event.get("queryStringParameters") or {})
    rows = db.run("""select s.id, s.assignment_id, s.student_email, s.filename, s.declared_bytes, s.size_bytes,
                            s.status, s.created_at, s.received_at
                       from submissions s
                      where (cast(:a as text) is null or s.assignment_id = :a)
                      order by s.created_at desc limit 200""", a=q.get("assignmentId"))
    return 200, {"submissions": rows}


def download_url(user, _event, params):
    require(user, "tutors")
    sub = db.one("select s3_key, status from submissions where id = cast(:i as uuid)", i=_uuid(params["submissionId"]))
    if not sub or sub["status"] != "received":
        raise HttpError(404, "no received submission with that id")
    url = _s3_public.generate_presigned_url("get_object", Params={"Bucket": os.environ["UPLOAD_BUCKET"],
                                                                   "Key": sub["s3_key"]}, ExpiresIn=300)
    return 200, {"url": url, "expiresInSeconds": 300}


def me(user, _event, _params):
    return 200, user


ROUTES = [
    ("GET", r"/me", me),
    ("GET", r"/exams", list_exams),
    ("POST", r"/exams", create_exam),
    ("POST", r"/exams/(?P<examId>[A-Za-z0-9_-]+)/attempts", start_attempt),
    ("POST", r"/exams/(?P<examId>[A-Za-z0-9_-]+)/release", release),
    ("GET", r"/attempts/(?P<attemptId>[0-9a-f-]+)", get_attempt),
    ("PUT", r"/attempts/(?P<attemptId>[0-9a-f-]+)/answers", autosave),
    ("POST", r"/attempts/(?P<attemptId>[0-9a-f-]+)/submit", submit),
    ("POST", r"/assignments/(?P<assignmentId>[A-Za-z0-9_-]+)/upload-url", upload_url),
    ("GET", r"/submissions", list_submissions),
    ("GET", r"/submissions/(?P<submissionId>[0-9a-f-]+)/download-url", download_url),
]


def _path(event):
    # Routes are matched without the /api prefix. API Gateway passes the part after /api as
    # the {proxy+} parameter; Floci 1.5.34 passes the whole path there, so strip the prefix
    # whichever source the path came from.
    proxy = (event.get("pathParameters") or {}).get("proxy")
    path = "/" + proxy.strip("/") if proxy else (event.get("path") or "/")
    if path == "/api" or path.startswith("/api/"):
        path = path[len("/api"):] or "/"
    return path


def handler(event, _context):
    # Direct invocation by the deploy script (not through API Gateway).
    if event.get("action") == "migrate":
        return db.migrate()
    method = event.get("httpMethod", "GET")
    path = _path(event)
    if method == "OPTIONS":
        return {"statusCode": 204, "headers": CORS, "body": ""}
    if path == "/health":
        row = db.one("select now() as db_time, inet_server_addr()::text as db_addr")
        return respond(200, {"status": "ok", "dbTime": row["db_time"], "region": os.environ.get("AWS_REGION")})
    try:
        for verb, pattern, fn in ROUTES:
            m = re.fullmatch(pattern, path)
            if m and verb == method:
                status, body = fn(caller(event), event, m.groupdict())
                return respond(status, body)
        raise HttpError(404, f"no route for {method} {path}")
    except HttpError as e:
        return respond(e.status, {"error": e.message})
