"""Verify Cognito ID tokens inside the function (standard library only).

On AWS the API Gateway Cognito authorizer already rejects bad tokens; this check runs
as well (defence in depth). On Floci 1.5.34 the Cognito authorizer does not enforce
anything, so this is the check that stands between a forged token and the data.

RS256: the signature is an RSA PKCS#1 v1.5 signature over SHA-256 of
"<header>.<payload>". Verifying it is one modular exponentiation and a byte-for-byte
comparison against the expected padded digest, which is why no crypto library is needed.
"""
import base64
import hashlib
import hmac
import json
import os
import time
import urllib.request

# DER prefix of DigestInfo for SHA-256 (RFC 8017, section 9.2, note 1)
_SHA256_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")
_keys = {}
_keys_fetched_at = 0.0


class TokenError(Exception):
    pass


def _b64(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def _issuer():
    return os.environ["COGNITO_ISSUER"].rstrip("/")


def _load_keys(force=False):
    global _keys, _keys_fetched_at
    if _keys and not force and time.time() - _keys_fetched_at < 3600:
        return _keys
    with urllib.request.urlopen(_issuer() + "/.well-known/jwks.json", timeout=5) as r:
        jwks = json.load(r)
    _keys = {k["kid"]: (int.from_bytes(_b64(k["n"]), "big"), int.from_bytes(_b64(k["e"]), "big"))
             for k in jwks.get("keys", []) if k.get("kty") == "RSA"}
    _keys_fetched_at = time.time()
    return _keys


def _rs256_valid(signing_input, signature, n, e):
    k = (n.bit_length() + 7) // 8
    if len(signature) != k:
        return False
    em = pow(int.from_bytes(signature, "big"), e, n).to_bytes(k, "big")
    digest = _SHA256_PREFIX + hashlib.sha256(signing_input).digest()
    expected = b"\x00\x01" + b"\xff" * (k - len(digest) - 3) + b"\x00" + digest
    return hmac.compare_digest(em, expected)


def verify(token):
    """Return the claims of a valid Cognito ID token for this app, or raise TokenError."""
    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
        header, claims, signature = json.loads(_b64(header_b64)), json.loads(_b64(payload_b64)), _b64(sig_b64)
    except (ValueError, json.JSONDecodeError):
        raise TokenError("malformed token")
    if header.get("alg") != "RS256":
        raise TokenError("unexpected signing algorithm")
    keys = _load_keys()
    if header.get("kid") not in keys:
        keys = _load_keys(force=True)  # the pool may have rotated its keys
    key = keys.get(header.get("kid"))
    if not key or not _rs256_valid(f"{header_b64}.{payload_b64}".encode(), signature, *key):
        raise TokenError("bad signature")
    if claims.get("iss") != _issuer():
        raise TokenError("wrong issuer")
    if claims.get("aud") != os.environ["COGNITO_CLIENT_ID"] or claims.get("token_use") != "id":
        raise TokenError("token is not an ID token for this app")
    if claims.get("exp", 0) < time.time():
        raise TokenError("token expired")
    return claims
