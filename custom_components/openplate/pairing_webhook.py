"""One-time HTTPS pairing endpoint for the OpenPlate iPhone app."""

from __future__ import annotations

import json
import secrets
import time
from dataclasses import dataclass
from typing import Any

from aiohttp import web
from homeassistant.components import webhook
from homeassistant.core import HomeAssistant

from .const import DOMAIN, MAX_BODY_BYTES, PAIRING_WEBHOOK_ID

_PAIRING_DATA_KEY = "pairing_gateway"


@dataclass(frozen=True)
class PairingOffer:
    """Credentials that may be collected once before expiry."""

    expires_at: float
    configuration: dict[str, Any]


class PairingGateway:
    """Hold short-lived offers in memory and serve them exactly once."""

    def __init__(self) -> None:
        self.offers: dict[str, PairingOffer] = {}

    def create_offer(
        self, configuration: dict[str, Any], *, lifetime_seconds: int
    ) -> tuple[str, int]:
        now = time.time()
        self._expire(now)
        token = secrets.token_urlsafe(32)
        expires_at = int(now + lifetime_seconds)
        self.offers[token] = PairingOffer(expires_at, dict(configuration))
        return token, expires_at

    async def handle_webhook(
        self, _hass: HomeAssistant, _webhook_id: str, request: web.Request
    ) -> web.Response:
        if request.content_length is not None and request.content_length > MAX_BODY_BYTES:
            return self._response({"error": "payload too large"}, status=413)
        body = await request.read()
        if len(body) > MAX_BODY_BYTES:
            return self._response({"error": "payload too large"}, status=413)
        try:
            payload = json.loads(body)
            token = payload["token"]
            if not isinstance(token, str):
                raise TypeError
        except (json.JSONDecodeError, KeyError, TypeError):
            return self._response({"error": "invalid pairing request"}, status=400)

        now = time.time()
        self._expire(now)
        offer = self.offers.pop(token, None)
        if offer is None:
            return self._response({"error": "invalid or expired pairing token"}, status=401)
        return self._response({"schema_version": 1, **offer.configuration}, status=200)

    def _expire(self, now: float) -> None:
        self.offers = {
            token: offer for token, offer in self.offers.items() if offer.expires_at > now
        }

    @staticmethod
    def _response(payload: dict[str, Any], *, status: int) -> web.Response:
        return web.json_response(
            payload,
            status=status,
            headers={
                "Cache-Control": "no-store",
                "Pragma": "no-cache",
                "Referrer-Policy": "no-referrer",
            },
        )


def async_ensure_pairing_gateway(hass: HomeAssistant) -> PairingGateway:
    """Register the global pairing webhook once, including during config flow."""
    domain_data = hass.data.setdefault(DOMAIN, {})
    gateway = domain_data.get(_PAIRING_DATA_KEY)
    if isinstance(gateway, PairingGateway):
        return gateway
    gateway = PairingGateway()
    domain_data[_PAIRING_DATA_KEY] = gateway
    webhook.async_register(
        hass,
        DOMAIN,
        "OpenPlate secure pairing",
        PAIRING_WEBHOOK_ID,
        gateway.handle_webhook,
        allowed_methods=["POST"],
    )
    return gateway
