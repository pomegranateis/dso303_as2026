"""Database access shared by the Lambda functions.

One connection per execution environment, opened lazily from the credentials
in Secrets Manager. On real AWS the host is the RDS Proxy endpoint, which pools
connections across thousands of concurrent invocations and keeps the client
connection alive while RDS fails over to the standby in the other AZ. If a
connection still drops (the failover window), `run` reconnects once and retries,
so an autosave issued during a failover succeeds on the retry instead of failing.
"""
import json
import os
import ssl

import boto3
import pg8000.native

_conn = None
_secret = None


def _credentials():
    global _secret
    if _secret is None:
        sm = boto3.client("secretsmanager")
        _secret = json.loads(sm.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])["SecretString"])
    return _secret


def _connect():
    creds = _credentials()
    ssl_context = None
    if os.environ.get("DB_SSL", "require") == "require":
        ssl_context = ssl.create_default_context()
    return pg8000.native.Connection(
        user=creds["username"],
        password=creds["password"],
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        database=os.environ.get("DB_NAME", "exams"),
        ssl_context=ssl_context,
        timeout=10,
        application_name=os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "exam-platform"),
    )


def run(sql, **params):
    """Run one statement and return rows as dicts. Reconnects once on a dropped connection."""
    global _conn
    for attempt in (1, 2):
        try:
            if _conn is None:
                _conn = _connect()
            rows = _conn.run(sql, **params)
            cols = [c["name"] for c in (_conn.columns or [])]
            return [dict(zip(cols, r)) for r in rows] if cols else []
        except (pg8000.exceptions.InterfaceError, OSError, ConnectionError):
            _conn = None
            if attempt == 2:
                raise
    return []


def one(sql, **params):
    rows = run(sql, **params)
    return rows[0] if rows else None


SCHEMA = [
    """create table if not exists exams (
         id text primary key, title text not null, duration_min int not null,
         opens_at timestamptz not null, closes_at timestamptz not null,
         released boolean not null default false, released_at timestamptz,
         tutor_email text not null)""",
    """create table if not exists questions (
         id text primary key, exam_id text not null references exams(id),
         position int not null, kind text not null check (kind in ('mcq','short')),
         prompt text not null, options jsonb, answer_key text, marks int not null default 1)""",
    """create table if not exists attempts (
         id uuid primary key, exam_id text not null references exams(id),
         student_id text not null, student_email text not null,
         started_at timestamptz not null, deadline timestamptz not null,
         submitted_at timestamptz, status text not null default 'in_progress',
         mcq_score numeric, max_mcq_score numeric, pending_short int,
         unique (exam_id, student_id))""",
    """create table if not exists answers (
         attempt_id uuid not null references attempts(id), question_id text not null,
         value text, client_seq int not null default 0, saved_at timestamptz not null,
         primary key (attempt_id, question_id))""",
    """create table if not exists assignments (
         id text primary key, title text not null, due_at timestamptz not null,
         tutor_email text not null)""",
    """create table if not exists submissions (
         id uuid primary key, assignment_id text not null references assignments(id),
         student_id text not null, student_email text not null, filename text not null,
         s3_key text not null unique, declared_bytes bigint not null, size_bytes bigint,
         content_type text not null, status text not null default 'pending_upload',
         created_at timestamptz not null default now(), received_at timestamptz)""",
]

SEED = [
    """insert into exams (id, title, duration_min, opens_at, closes_at, tutor_email)
       values ('DSO303-QUIZ1', 'DSO303 Quiz 1 - Cloud Architecture', 30,
               now() - interval '1 day', now() + interval '365 days', 'tutor1@exams.example.edu')
       on conflict (id) do nothing""",
    """insert into questions (id, exam_id, position, kind, prompt, options, answer_key, marks) values
       ('Q1','DSO303-QUIZ1',1,'mcq','Which RDS feature keeps a synchronous standby in a second Availability Zone?',
        '["Read replica","Multi-AZ deployment","Automated backups","Performance Insights"]'::jsonb,'Multi-AZ deployment',1),
       ('Q2','DSO303-QUIZ1',2,'mcq','Which service lets a browser upload a 40 MB file straight to S3 without passing through the API?',
        '["S3 presigned POST","API Gateway binary media","Lambda function URL","CloudFront Functions"]'::jsonb,'S3 presigned POST',1),
       ('Q3','DSO303-QUIZ1',3,'mcq','What does an SQS dead-letter queue hold?',
        '["Messages that failed processing too many times","Messages older than 14 days","Delayed messages","FIFO duplicates"]'::jsonb,
        'Messages that failed processing too many times',1),
       ('Q4','DSO303-QUIZ1',4,'short','In two sentences, explain why the exam API autosaves every 30 seconds.',null,null,2)
       on conflict (id) do nothing""",
    """insert into assignments (id, title, due_at, tutor_email)
       values ('DSO303-A2', 'DSO303 Assignment 2 - Architecture Design', now() + interval '30 days',
               'tutor1@exams.example.edu')
       on conflict (id) do nothing""",
]


def migrate():
    for stmt in SCHEMA + SEED:
        run(stmt)
    return {"tables": len(SCHEMA), "seeded": True}
