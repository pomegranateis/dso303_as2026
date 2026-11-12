"""Email queue worker: turns queued notifications into SES emails.

Messages are either EventBridge SubmissionReceived events (tutor notification and a
student receipt) or result_email jobs queued by the marker on release. This function
needs no database and runs outside the VPC. Its reserved concurrency caps the send
rate below the SES sending quota, so a 3,000-email release drains steadily from SQS
instead of being throttled by SES.
"""
import json
import os

import boto3

_ses = boto3.client("ses")
SENDER = os.environ.get("SES_SENDER", "no-reply@exams.example.edu")


def _send(to, subject, text):
    resp = _ses.send_email(Source=SENDER, Destination={"ToAddresses": [to]},
                           Message={"Subject": {"Data": subject}, "Body": {"Text": {"Data": text}}})
    print(json.dumps({"level": "INFO", "msg": "email sent", "to": to, "subject": subject,
                      "messageId": resp.get("MessageId")}))


def _submission(detail):
    mb = detail["sizeBytes"] / (1024 * 1024)
    if detail["status"] == "received":
        _send(detail["tutorEmail"], f"New submission: {detail['assignmentTitle']}",
              f"{detail['studentEmail']} submitted {detail['filename']} ({mb:.1f} MB) for "
              f"{detail['assignmentTitle']}.\nSubmission ID: {detail['submissionId']}\n"
              "Open the tutor dashboard to download it.")
        _send(detail["studentEmail"], f"Receipt: {detail['assignmentTitle']}",
              f"We received {detail['filename']} ({mb:.1f} MB). Submission ID: {detail['submissionId']}.")
    else:
        _send(detail["studentEmail"], f"Upload rejected: {detail['assignmentTitle']}",
              f"{detail['filename']} is not a valid PDF or ZIP file under 50 MB. Please upload it again.")


def _result(job):
    pending = f"\n{job['pendingShort']} short answer(s) will be marked by your tutor." if job["pendingShort"] else ""
    _send(job["to"], f"Results released: {job['examTitle']}",
          f"Your multiple-choice score for {job['examTitle']}: {job['mcqScore']:g} / {job['maxMcqScore']:g}.{pending}")


def handler(event, _context):
    failures = []
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            if body.get("detail-type") == "SubmissionReceived":
                _submission(body["detail"])
            elif body.get("type") == "result_email":
                _result(body)
            else:
                print(json.dumps({"level": "WARN", "msg": "unknown message", "body": body}))
        except Exception as exc:
            print(json.dumps({"level": "ERROR", "msg": str(exc), "messageId": record.get("messageId")}))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
