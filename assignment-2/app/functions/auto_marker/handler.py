"""Marking queue worker.

Two message shapes arrive on the marking queue:
  {"type": "mark", "attemptId": ...}          sent by the API when a student submits
  an EventBridge ResultsReleased event         routed here by a rule on the exam bus
A submitted attempt has its MCQs auto-marked; short answers stay pending for the tutor.
On release, one email job per student is queued on the email queue (in batches of 10),
so a 3,000-student release is spread over the notifier instead of one long API call.
"""
import json
import os

import boto3

import db

_sqs = boto3.client("sqs")


def mark(attempt_id):
    attempt = db.one("select * from attempts where id = cast(:a as uuid)", a=attempt_id)
    if not attempt or attempt["status"] not in ("submitted", "marked"):
        return None
    rows = db.run("""select q.id, q.kind, q.answer_key, q.marks, a.value
                       from questions q left join answers a
                         on a.question_id = q.id and a.attempt_id = cast(:a as uuid)
                      where q.exam_id = :e""", a=attempt_id, e=attempt["exam_id"])
    score = sum(r["marks"] for r in rows if r["kind"] == "mcq" and r["value"] == r["answer_key"])
    max_score = sum(r["marks"] for r in rows if r["kind"] == "mcq")
    pending = sum(1 for r in rows if r["kind"] == "short")
    db.run("""update attempts set status = 'marked', mcq_score = :s, max_mcq_score = :m, pending_short = :p
              where id = cast(:a as uuid)""", s=score, m=max_score, p=pending, a=attempt_id)
    print(json.dumps({"level": "INFO", "msg": "attempt marked", "attemptId": attempt_id,
                      "mcqScore": score, "maxMcqScore": max_score, "pendingShort": pending}))
    return score


def fan_out_results(exam_id):
    exam = db.one("select id, title from exams where id = :e", e=exam_id)
    attempts = db.run("""select id, student_email, mcq_score, max_mcq_score, pending_short
                           from attempts where exam_id = :e and status = 'marked'""", e=exam_id)
    batch, queued = [], 0
    for a in attempts:
        batch.append({"Id": str(len(batch)), "MessageBody": json.dumps({
            "type": "result_email", "to": a["student_email"], "examId": exam["id"], "examTitle": exam["title"],
            "mcqScore": float(a["mcq_score"] or 0), "maxMcqScore": float(a["max_mcq_score"] or 0),
            "pendingShort": a["pending_short"]})})
        if len(batch) == 10:
            _sqs.send_message_batch(QueueUrl=os.environ["EMAIL_QUEUE_URL"], Entries=batch)
            queued += len(batch)
            batch = []
    if batch:
        _sqs.send_message_batch(QueueUrl=os.environ["EMAIL_QUEUE_URL"], Entries=batch)
        queued += len(batch)
    print(json.dumps({"level": "INFO", "msg": "result emails queued", "examId": exam_id, "count": queued}))


def handler(event, _context):
    failures = []
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            if body.get("detail-type") == "ResultsReleased":
                fan_out_results(body["detail"]["examId"])
            elif body.get("type") == "mark":
                mark(body["attemptId"])
            else:
                print(json.dumps({"level": "WARN", "msg": "unknown message", "body": body}))
        except Exception as exc:
            print(json.dumps({"level": "ERROR", "msg": str(exc), "messageId": record.get("messageId")}))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
