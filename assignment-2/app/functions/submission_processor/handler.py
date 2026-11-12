"""S3 upload -> SQS -> this function (walkthrough 2, the asynchronous half).

For each ObjectCreated record it checks the object really is what the student
declared (size within 50 MB, PDF or ZIP magic bytes), marks the submission as
received or rejected in RDS, and publishes SubmissionReceived on the exam event
bus. An EventBridge rule routes that event to the email queue, where the notifier
emails the tutor. Failed records are reported individually, so SQS retries only
those and moves a record that keeps failing to the dead-letter queue.
"""
import datetime
import json
import os
import urllib.parse

import boto3

import db

MAX_BYTES = 50 * 1024 * 1024
MAGIC = {b"%PDF-": "application/pdf", b"PK\x03\x04": "application/zip"}

_s3 = boto3.client("s3")
_events = boto3.client("events")


def _s3_records(body):
    msg = json.loads(body)
    if msg.get("Event") == "s3:TestEvent":  # sent once when the notification is configured
        return []
    return msg.get("Records") or []


def _process(rec):
    bucket = rec["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(rec["s3"]["object"]["key"])
    sub = db.one("select * from submissions where s3_key = :k", k=key)
    if not sub:
        print(json.dumps({"level": "WARN", "msg": "object has no submission record", "key": key}))
        return
    head = _s3.head_object(Bucket=bucket, Key=key)
    size = head["ContentLength"]
    first = _s3.get_object(Bucket=bucket, Key=key, Range="bytes=0-7")["Body"].read()
    detected = next((t for magic, t in MAGIC.items() if first.startswith(magic)), None)
    ok = size <= MAX_BYTES and detected is not None and (
        detected == sub["content_type"] or sub["content_type"] == "application/x-zip-compressed")
    status = "received" if ok else "rejected"
    db.run("update submissions set status = :st, size_bytes = :b, received_at = :t where id = cast(:i as uuid)",
           st=status, b=size, t=datetime.datetime.now(datetime.timezone.utc), i=str(sub["id"]))
    assignment = db.one("select title, tutor_email from assignments where id = :a", a=sub["assignment_id"])
    detail = {
        "submissionId": str(sub["id"]), "assignmentId": sub["assignment_id"],
        "assignmentTitle": assignment["title"], "tutorEmail": assignment["tutor_email"],
        "studentEmail": sub["student_email"], "filename": sub["filename"],
        "sizeBytes": size, "status": status, "detectedType": detected,
    }
    _events.put_events(Entries=[{"EventBusName": os.environ["EVENT_BUS_NAME"], "Source": "exam-platform.uploads",
                                 "DetailType": "SubmissionReceived", "Detail": json.dumps(detail)}])
    print(json.dumps({"level": "INFO", "msg": "submission processed", **detail}))


def handler(event, _context):
    failures = []
    for record in event.get("Records", []):
        try:
            for rec in _s3_records(record["body"]):
                _process(rec)
        except Exception as exc:  # report this message only; the rest of the batch is kept
            print(json.dumps({"level": "ERROR", "msg": str(exc), "messageId": record.get("messageId")}))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
