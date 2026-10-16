"""Build the local QR pairing payload shared with the iPhone app."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from ipaddress import ip_address, ip_network
from urllib.parse import urlencode, urlsplit, urlunsplit


def normalize_base_url(value: str, *, require_https: bool = False) -> str:
    """Allow HTTPS or local HTTP for the encrypted HA channel, never URL credentials."""
    parsed = urlsplit(value.strip())
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or any(character.isspace() for character in value)
    ):
        raise ValueError("A plain HTTP(S) base URL is required")
    try:
        _ = parsed.port
    except ValueError as err:
        raise ValueError("Invalid port") from err
    if parsed.scheme == "http" and (require_https or not _local_host(parsed.hostname)):
        raise ValueError("HTTP is restricted to local Home Assistant addresses")
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/"), "", ""))


def _local_host(host: str) -> bool:
    try:
        address = ip_address(host)
        networks = (
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "127.0.0.0/8",
            "169.254.0.0/16",
            "fc00::/7",
            "fe80::/10",
            "::1/128",
        )
        return any(address in ip_network(network) for network in networks)
    except ValueError:
        return ":" not in host and (
            "." not in host or host.lower().endswith((".local", ".lan", ".home.arpa"))
        )


def normalize_https_base_url(value: str) -> str:
    return normalize_base_url(value, require_https=True)


def build_pairing_uri(
    *,
    home_assistant_url: str,
    pairing_webhook_id: str,
    offer_id: str,
    key: str,
    issued_at: datetime | None = None,
    lifetime_seconds: int = 600,
) -> str:
    """Return the temporary out-of-band key. It must NEVER be sent over HTTP."""
    base_url = normalize_base_url(home_assistant_url)
    if not pairing_webhook_id.strip() or len(key) < 32 or len(offer_id) < 16:
        raise ValueError("Incomplete pairing data")
    created = issued_at or datetime.now(timezone.utc)
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    expires_at = int((created + timedelta(seconds=lifetime_seconds)).timestamp())
    pairing_url = f"{base_url}/api/webhook/{pairing_webhook_id}"
    query = urlencode(
        {
            "version": "2",
            "pairing_url": pairing_url,
            "offer_id": offer_id,
            "key": key,
            "expires_at": str(expires_at),
        }
    )
    return f"openplate://pair?{query}"
