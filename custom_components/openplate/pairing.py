"""Build the local QR pairing payload shared with the iPhone app."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode, urlsplit, urlunsplit


def normalize_https_base_url(value: str) -> str:
    """Validate and normalize a Home Assistant HTTPS base URL."""
    parsed = urlsplit(value.strip())
    if parsed.scheme.lower() != "https" or not parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError("A plain HTTPS base URL is required")
    return urlunsplit(("https", parsed.netloc, parsed.path.rstrip("/"), "", ""))


def build_pairing_uri(
    *,
    home_assistant_url: str,
    pairing_webhook_id: str,
    token: str,
    issued_at: datetime | None = None,
    lifetime_seconds: int = 600,
) -> str:
    """Return a versioned URI containing only a short-lived bearer token."""
    base_url = normalize_https_base_url(home_assistant_url)
    if not pairing_webhook_id.strip() or len(token) < 32:
        raise ValueError("Incomplete pairing data")
    created = issued_at or datetime.now(timezone.utc)
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    expires_at = int((created + timedelta(seconds=lifetime_seconds)).timestamp())
    pairing_url = f"{base_url}/api/webhook/{pairing_webhook_id}"
    query = urlencode(
        {
            "version": "1",
            "pairing_url": pairing_url,
            "token": token,
            "expires_at": str(expires_at),
        }
    )
    return f"openplate://pair?{query}"
