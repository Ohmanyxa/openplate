"""One-time encrypted pairing, including over local HTTP."""

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
from .encryption import seal, unseal

_PAIRING_DATA_KEY = "pairing_gateway"


@dataclass(frozen=True)
class PairingOffer:
    """Credentials that may be collected once before expiry."""

    expires_at: float
    configuration: dict[str, Any]
    key: str


class PairingGateway:
    """Hold short-lived offers in memory and serve them exactly once."""

    def __init__(self) -> None:
        self.offers: dict[str, PairingOffer] = {}

    def create_offer(
        self, configuration: dict[str, Any], *, lifetime_seconds: int
    ) -> tuple[str, str, int]:
        now = time.time()
        self._expire(now)
        offer_id = secrets.token_urlsafe(18)
        key = secrets.token_urlsafe(32)
        expires_at = int(now + lifetime_seconds)
        self.offers[offer_id] = PairingOffer(expires_at, dict(configuration), key)
        return offer_id, key, expires_at

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
            offer_id = payload["offer_id"]
            if not isinstance(offer_id, str):
                raise TypeError
        except (ValueError, KeyError, TypeError):
            return self._response({"error": "invalid pairing request"}, status=400)

        now = time.time()
        self._expire(now)
        offer = self.offers.get(offer_id)
        if offer is None:
            return self._response({"error": "invalid or expired pairing token"}, status=401)
        try:
            request_data = unseal(payload["envelope"], offer.key, f"pairing/request/{offer_id}")
            if request_data != {"action": "pair", "offer_id": offer_id}:
                raise ValueError
        except (ValueError, KeyError, TypeError):
            return self._response({"error": "invalid encrypted pairing request"}, status=401)
        self.offers.pop(offer_id)
        response = seal(
            {"schema_version": 1, **offer.configuration},
            offer.key,
            f"pairing/response/{offer_id}/{payload['envelope']['id']}/200",
        )
        return self._response(response, status=200)

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
