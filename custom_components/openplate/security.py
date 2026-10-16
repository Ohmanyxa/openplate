"""Standard HMAC authentication helpers without Home Assistant dependencies."""

from __future__ import annotations

import hashlib
import hmac
import time


def signature_for(secret: str, timestamp: str, nonce: str, body: bytes) -> str:
    message = timestamp.encode() + b"\n" + nonce.encode() + b"\n" + body
    return hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()


def valid_signature(
    secret: str,
    timestamp: str,
    nonce: str,
    body: bytes,
    received_signature: str,
    *,
    now: float | None = None,
    max_age_seconds: int = 90,
) -> bool:
    try:
        sent_at = int(timestamp)
    except (TypeError, ValueError):
        return False
    current = time.time() if now is None else now
    if abs(current - sent_at) > max_age_seconds or not nonce:
        return False
    expected = signature_for(secret, timestamp, nonce, body)
    return hmac.compare_digest(expected, received_signature)
