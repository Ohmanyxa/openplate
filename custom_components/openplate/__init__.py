"""OpenPlate local-push integration."""

from __future__ import annotations

import json
import re
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from aiohttp import web
from homeassistant.components import webhook
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.event import async_track_time_interval

from .const import (
    CONF_ABSENCE_TIMEOUT,
    CONF_DEVICE_ID,
    CONF_PLATES,
    CONF_SECRET,
    CONF_WEBHOOK_ID,
    DOMAIN,
    MAX_BODY_BYTES,
    PLATFORMS,
    SIGNATURE_MAX_AGE_SECONDS,
)
from .security import valid_signature

_NOT_ALNUM = re.compile(r"[^A-Z0-9]")


def normalize_plate(value: str) -> str:
    return _NOT_ALNUM.sub("", value.upper())


def parse_plates(value: str) -> dict[str, str]:
    plates: dict[str, str] = {}
    for raw_line in value.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        plate, separator, name = line.partition("=")
        normalized = normalize_plate(plate)
        if normalized:
            plates[normalized] = name.strip() if separator and name.strip() else normalized
    return plates


@dataclass
class PlatePresence:
    last_seen: float = 0.0
    present: bool = False


class OpenPlateManager:
    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        self.config = {**entry.data, **entry.options}
        self.plates = parse_plates(self.config[CONF_PLATES])
        self.presence = {plate: PlatePresence() for plate in self.plates}
        self.last_event: dict[str, Any] | None = None
        self._listeners: list[Callable[[str, dict[str, Any]], None]] = []
        self._nonces: dict[str, float] = {}

    def subscribe(self, listener: Callable[[str, dict[str, Any]], None]) -> Callable[[], None]:
        self._listeners.append(listener)
        return lambda: self._listeners.remove(listener)

    @callback
    def notify(self, event_type: str, data: dict[str, Any]) -> None:
        for listener in self._listeners:
            listener(event_type, data)

    async def handle_webhook(
        self, _hass: HomeAssistant, _webhook_id: str, request: web.Request
    ) -> web.Response:
        if request.content_length is not None and request.content_length > MAX_BODY_BYTES:
            return web.json_response({"error": "payload too large"}, status=413)
        body = await request.read()
        if len(body) > MAX_BODY_BYTES:
            return web.json_response({"error": "payload too large"}, status=413)
        timestamp = request.headers.get("X-OpenPlate-Timestamp", "")
        nonce = request.headers.get("X-OpenPlate-Nonce", "")
        signature = request.headers.get("X-OpenPlate-Signature", "")
        now = time.time()
        self._expire_nonces(now)
        if nonce in self._nonces:
            return web.json_response({"error": "replayed request"}, status=409)
        if not valid_signature(
            self.config[CONF_SECRET],
            timestamp,
            nonce,
            body,
            signature,
            now=now,
            max_age_seconds=SIGNATURE_MAX_AGE_SECONDS,
        ):
            return web.json_response({"error": "invalid signature"}, status=401)
        self._nonces[nonce] = now
        try:
            payload = json.loads(body)
            self._validate_payload(payload)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            return web.json_response({"error": "invalid payload"}, status=400)
        self.process_observation(payload, now)
        return web.json_response({"accepted": True})

    def _validate_payload(self, payload: dict[str, Any]) -> None:
        if payload["schema_version"] != 1 or payload["event_type"] != "plate.observed":
            raise ValueError
        if payload["device_id"] != self.config[CONF_DEVICE_ID]:
            raise ValueError
        if not isinstance(payload["event_id"], str) or not isinstance(payload["plate"], str):
            raise TypeError
        confidence = float(payload["confidence"])
        observations = int(payload["observations"])
        if not 0 <= confidence <= 1 or observations < 1:
            raise ValueError
        datetime.fromisoformat(payload["timestamp"].replace("Z", "+00:00"))

    @callback
    def process_observation(self, payload: dict[str, Any], now: float) -> None:
        plate = normalize_plate(payload["plate"])
        registered = plate in self.plates
        data = {
            **payload,
            "plate": plate,
            "registered": registered,
            "display_name": self.plates.get(plate),
        }
        self.last_event = data
        self.notify("recognized", data)
        if not registered:
            return
        state = self.presence[plate]
        was_present = state.present
        state.present = True
        state.last_seen = now
        if not was_present:
            self.notify("appeared", data)
        self.notify("state", data)

    @callback
    def check_departures(self, _now: datetime) -> None:
        current = time.time()
        timeout = int(self.config[CONF_ABSENCE_TIMEOUT])
        for plate, state in self.presence.items():
            if state.present and current - state.last_seen >= timeout:
                state.present = False
                data = {
                    "plate": plate,
                    "display_name": self.plates[plate],
                    "registered": True,
                    "device_id": self.config[CONF_DEVICE_ID],
                }
                self.notify("disappeared", data)
                self.notify("state", data)

    def _expire_nonces(self, now: float) -> None:
        cutoff = now - SIGNATURE_MAX_AGE_SECONDS
        self._nonces = {nonce: seen for nonce, seen in self._nonces.items() if seen >= cutoff}


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    manager = OpenPlateManager(hass, entry)
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = manager
    webhook.async_register(
        hass,
        DOMAIN,
        entry.title,
        entry.data[CONF_WEBHOOK_ID],
        manager.handle_webhook,
        allowed_methods=["POST"],
    )
    entry.async_on_unload(
        async_track_time_interval(hass, manager.check_departures, timedelta(seconds=5))
    )
    entry.async_on_unload(entry.add_update_listener(_async_reload_entry))
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_migrate_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Migrate entries created before the guided pairing flow."""
    if entry.version == 1:
        hass.config_entries.async_update_entry(entry, version=2)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unloaded:
        webhook.async_unregister(hass, entry.data[CONF_WEBHOOK_ID])
        hass.data[DOMAIN].pop(entry.entry_id)
    return unloaded


async def _async_reload_entry(hass: HomeAssistant, entry: ConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)
