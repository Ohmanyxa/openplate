"""Version 2 authenticated envelopes using AES-256-GCM and HKDF-SHA256."""

from __future__ import annotations

import base64
import binascii
import json
import re
import secrets
import time
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

_ID = re.compile(r"^[A-Za-z0-9_-]{16,64}$")
_SALT = b"openplate/v2/hkdf-sha256"
MAX_AGE = 90


def _decode(value: str) -> bytes:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+={0,2}", value):
        raise ValueError("Invalid base64url")
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def _encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def _key(secret: str, context: str) -> bytes:
    if len(secret) < 32:
        raise ValueError("Secret too short")
    return HKDF(
        algorithm=hashes.SHA256(), length=32, salt=_SALT, info=f"openplate/v2/{context}".encode()
    ).derive(secret.encode())


def seal(
    payload: dict[str, Any],
    secret: str,
    context: str,
    *,
    message_id: str | None = None,
    now: float | None = None,
    nonce: bytes | None = None,
) -> dict[str, Any]:
    """Encrypt a JSON object; directions and responses have distinct key contexts."""
    message_id = message_id or secrets.token_urlsafe(18)
    if not _ID.fullmatch(message_id):
        raise ValueError("Invalid message ID")
    timestamp = int(time.time() if now is None else now)
    iv = nonce if nonce is not None else secrets.token_bytes(12)
    if len(iv) != 12:
        raise ValueError("Invalid nonce")
    aad = f"openplate/v2\n{context}\n{message_id}\n{timestamp}".encode()
    plaintext = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
    encrypted = AESGCM(_key(secret, context)).encrypt(iv, plaintext, aad)
    return {
        "version": 2,
        "id": message_id,
        "timestamp": timestamp,
        "nonce": _encode(iv),
        "ciphertext": _encode(encrypted),
    }


def unseal(
    envelope: dict[str, Any],
    secret: str,
    context: str,
    *,
    now: float | None = None,
) -> dict[str, Any]:
    """Authenticate metadata and decrypt, rejecting malformed or stale messages."""
    try:
        if not isinstance(envelope, dict) or envelope["version"] != 2:
            raise ValueError
        message_id, timestamp = envelope["id"], envelope["timestamp"]
        if not isinstance(message_id, str) or not _ID.fullmatch(message_id):
            raise ValueError
        if type(timestamp) is not int:
            raise ValueError
        if abs((time.time() if now is None else now) - timestamp) > MAX_AGE:
            raise ValueError
        iv, ciphertext = _decode(envelope["nonce"]), _decode(envelope["ciphertext"])
        if len(iv) != 12 or len(ciphertext) < 16:
            raise ValueError
        aad = f"openplate/v2\n{context}\n{message_id}\n{timestamp}".encode()
        plaintext = AESGCM(_key(secret, context)).decrypt(iv, ciphertext, aad)
        payload = json.loads(plaintext)
        if not isinstance(payload, dict):
            raise ValueError
        return payload
    except (InvalidTag, KeyError, TypeError, ValueError, binascii.Error, UnicodeError) as err:
        raise ValueError("Invalid encrypted message") from err
