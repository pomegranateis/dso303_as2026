"""HTTP helpers for API Gateway proxy integrations: responses, CORS and caller identity."""
import base64
import datetime
import decimal
import json
import os
import uuid

import auth

CORS = {
    "Access-Control-Allow-Origin": os.environ.get("ALLOWED_ORIGIN", "*"),
    "Access-Control-Allow-Headers": "Authorization,Content-Type",
    "Access-Control-Allow-Methods": "GET,POST,PUT,OPTIONS",
}


def _default(o):
    if isinstance(o, (datetime.datetime, datetime.date)):
        return o.isoformat()
    if isinstance(o, decimal.Decimal):
        return float(o)
    if isinstance(o, uuid.UUID):
        return str(o)
    raise TypeError(type(o).__name__)


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", **CORS},
        "body": json.dumps(body, default=_default),
    }


class HttpError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def body_json(event):
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        raise HttpError(400, "request body is not valid JSON")


def caller(event):
    """The signed-in user. The token's signature, issuer, audience and expiry are checked
    here on every request (see auth.py), whatever the API Gateway authorizer did."""
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    token = (headers.get("authorization") or "").split()[-1:] or [""]
    try:
        claims = auth.verify(token[0])
    except auth.TokenError as exc:
        raise HttpError(401, f"not signed in: {exc}")
    groups = claims.get("cognito:groups") or []
    if isinstance(groups, str):
        groups = [g for g in groups.strip("[]").replace(",", " ").split() if g]
    return {
        "id": claims.get("sub"),
        "email": claims.get("email") or claims.get("cognito:username"),
        "username": claims.get("cognito:username"),
        "groups": groups,
    }


def require(user, *roles):
    if not set(roles) & set(user["groups"]) and "admins" not in user["groups"]:
        raise HttpError(403, f"this action needs one of: {', '.join(roles)}")
