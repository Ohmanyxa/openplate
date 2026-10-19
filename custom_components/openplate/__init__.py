"""OpenPlate local-push integration."""

from __future__ import annotations

import json
import logging
import re
import secrets
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
from homeassistant.helpers.typing import ConfigType

from .configuration import mobile_configuration
from .const import (
    CONF_ABSENCE_TIMEOUT,
    CONF_DEVICE_ID,
    CONF_PLATES,
    CONF_SECRET,
    CONF_TRANSPORT_VERSION,
    CONF_WEBHOOK_ID,
    DOMAIN,
    MAX_BODY_BYTES,
    PLATFORMS,
    SIGNATURE_MAX_AGE_SECONDS,
)
from .encryption import seal, unseal
from .garages import movement_status, validate_garage
from .pairing_webhook import async_ensure_pairing_gateway
from .plates import normalize_plate, parse_plates
from .security import valid_signature

_LOGGER = logging.getLogger(__name__)


@dataclass
class PlatePresence:
    last_seen: float = 0.0
    present: bool = False
    motion: dict[str, Any] | None = None


class OpenPlateManager:
    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        self.config = {**entry.data, **entry.options}
        self.plates = parse_plates(self.config[CONF_PLATES])
        self.garages = {
            plate: entity
            for plate, entity in self.config.get("plate_garages", {}).items()
            if plate in self.plates
            and isinstance(entity, str)
            and re.fullmatch(r"cover\.[a-z0-9_]+", entity)
        }
        self.presence = {plate: PlatePresence() for plate in self.plates}
        self.garage_instances: dict[str, dict[str, Any]] = {}
        for key, value in self.config.get("garages", {}).items():
            try:
                validate_garage(value, self.plates)
            except (ValueError, TypeError):
                continue
            self.garage_instances[key] = value
        self.garage_states = {
            key: {"status": "unknown", "plate": None, "action_result": "none"}
            for key in self.garage_instances
        }
        self._garage_directions: dict[tuple[str, str], str] = {}
        self._garage_actions: dict[str, float] = {}
        self._garage_busy: set[str] = set()
        self.last_event: dict[str, Any] | None = None
        self._listeners: list[Callable[[str, dict[str, Any]], None]] = []
        self._nonces: dict[str, float] = {}
        self._session_id = secrets.token_urlsafe(24)
        self._event_ids: dict[str, float] = {}

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
        try:
            envelope = json.loads(body)
        except (ValueError, UnicodeError):
            return web.json_response({"error": "invalid payload"}, status=400)
        if isinstance(envelope, dict) and envelope.get("version") == 2:
            return self._handle_encrypted(envelope)
        # Legacy plaintext is accepted only for existing HTTPS configurations.
        # Re-pairing permanently opts an entry into encrypted-only transport.
        if self.config.get(CONF_TRANSPORT_VERSION, 1) != 1 or not self.config.get(
            "home_assistant_url", ""
        ).startswith("https://"):
            return web.json_response({"error": "encrypted transport required"}, status=426)
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
            if (
                isinstance(payload, dict)
                and payload.get("schema_version") == 1
                and payload.get("event_type") == "device.configuration"
                and payload.get("device_id") == self.config[CONF_DEVICE_ID]
            ):
                return web.json_response(
                    {"schema_version": 1, **mobile_configuration(self.config)},
                    headers={"Cache-Control": "no-store", "Pragma": "no-cache"},
                )
            self._validate_payload(payload)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            return web.json_response({"error": "invalid payload"}, status=400)
        self.process_observation(payload, now)
        return web.json_response({"accepted": True})

    def _handle_encrypted(self, envelope: dict[str, Any]) -> web.Response:
        webhook_id = self.config[CONF_WEBHOOK_ID]
        secret = self.config[CONF_SECRET]
        now = time.time()
        try:
            payload = unseal(envelope, secret, f"device/request/{webhook_id}", now=now)
        except ValueError:
            return web.json_response({"error": "invalid encrypted request"}, status=401)
        message_id = envelope["id"]

        def respond(data: dict[str, Any], status: int = 200) -> web.Response:
            return web.json_response(
                seal(data, secret, f"device/response/{webhook_id}/{message_id}/{status}"),
                status=status,
                headers={"Cache-Control": "no-store", "Pragma": "no-cache"},
            )

        self._expire_nonces(now)
        replay_id = f"v2:{message_id}"
        if replay_id in self._nonces:
            return respond({"error": "replayed request"}, 409)
        self._nonces[replay_id] = now
        if (
            payload.get("schema_version") != 1
            or payload.get("device_id") != self.config[CONF_DEVICE_ID]
        ):
            return respond({"error": "invalid device"}, 400)
        if payload.get("event_type") == "device.configuration":
            return respond(
                {
                    "schema_version": 1,
                    **mobile_configuration(self.config),
                    "session_id": self._session_id,
                }
            )
        # Fresh server sessions make recorded plate messages unusable after a reload/restart.
        if payload.get("session_id") != self._session_id:
            return respond({"error": "session required"}, 428)
        try:
            self._validate_payload(payload)
        except (KeyError, TypeError, ValueError):
            return respond({"error": "invalid payload"}, 400)
        event_id = payload["event_id"]
        if event_id in self._event_ids:
            return respond({"accepted": True, "duplicate": True})
        self._event_ids[event_id] = now
        self.process_observation(
            {key: value for key, value in payload.items() if key != "session_id"}, now
        )
        return respond({"accepted": True})

    def _validate_payload(self, payload: dict[str, Any]) -> None:
        # This endpoint accepts observations, never images, frames or arbitrary blobs.
        allowed = {
            "schema_version",
            "event_type",
            "device_id",
            "event_id",
            "timestamp",
            "plate",
            "confidence",
            "observations",
            "session_id",
            "motion",
        }
        if not isinstance(payload, dict) or set(payload) - allowed:
            raise ValueError
        if payload["schema_version"] != 1 or payload["event_type"] != "plate.observed":
            raise ValueError
        if payload["device_id"] != self.config[CONF_DEVICE_ID]:
            raise ValueError
        if not isinstance(payload["event_id"], str) or not isinstance(payload["plate"], str):
            raise TypeError
        if not 1 <= len(payload["event_id"]) <= 128 or not re.fullmatch(
            r"[A-Za-zÄÖÜäöü0-9 -]{1,16}", payload["plate"]
        ):
            raise ValueError
        confidence = float(payload["confidence"])
        observations = int(payload["observations"])
        if not 0 <= confidence <= 1 or observations < 1:
            raise ValueError
        datetime.fromisoformat(payload["timestamp"].replace("Z", "+00:00"))
        if "motion" in payload:
            from .motion import validate_motion

            validate_motion(payload["motion"])

    @callback
    def process_observation(self, payload: dict[str, Any], now: float) -> None:
        plate = normalize_plate(payload["plate"])
        registered = plate in self.plates
        data = {
            **payload,
            "plate": plate,
            "registered": registered,
            "display_name": self.plates.get(plate),
            "garage_entity_id": self.garages.get(plate),
        }
        self.last_event = data
        self.notify("recognized", data)
        if not registered:
            return
        state = self.presence[plate]
        was_present = state.present
        state.present = True
        state.last_seen = now
        state.motion = data.get("motion")
        if not was_present:
            self.notify("appeared", data)
        self.notify("state", data)
        self._process_garages(data, now)

    def _process_garages(self, data: dict[str, Any], now: float) -> None:
        for key, garage in self.garage_instances.items():
            if data["plate"] not in garage["plates"]:
                continue
            status = movement_status(data.get("motion"), garage["arrival_direction"])
            if status is None:
                continue
            latch = (key, data["plate"])
            if self._garage_directions.get(latch) == status:
                continue
            self._garage_directions[latch] = status
            state = self.garage_states[key]
            state.update(status=status, plate=data["plate"], action_result="disabled")
            self.notify(status, {**data, "garage_id": key, "status": status})
            action = garage[f"{status}_action"]
            if not garage["enabled"] or action == "none":
                continue
            # Only fresh, confirmed, encrypted/session-bound observations may actuate.
            try:
                observed = datetime.fromisoformat(data["timestamp"].replace("Z", "+00:00"))
                fresh = observed.tzinfo is not None and abs(now - observed.timestamp()) <= 15
                confirmed = float(data["confidence"]) >= 0.8 and int(data["observations"]) >= 3
            except (KeyError, TypeError, ValueError, OverflowError):
                fresh = confirmed = False
            if not fresh or not confirmed or self.config.get(CONF_TRANSPORT_VERSION) != 2:
                state["action_result"] = "rejected"
            elif key in self._garage_busy or now - self._garage_actions.get(key, now - 60) < 60:
                state["action_result"] = "cooldown"
            else:
                self._garage_actions[key] = now
                self._garage_busy.add(key)
                state["action_result"] = "pending"
                self.entry.async_create_background_task(
                    self.hass, self._actuate_garage(key, action), f"OpenPlate garage {key}"
                )
            self.notify("state", {"garage_id": key})

    async def _actuate_garage(self, key: str, action: str) -> None:
        garage = self.garage_instances[key]
        state = self.garage_states[key]
        domain = garage["target"].split(".")[0]
        service = {"open": "open_cover", "close": "close_cover", "on": "turn_on", "off": "turn_off"}
        try:
            target = self.hass.states.get(garage["target"])
            if target is None or target.state in {"unknown", "unavailable"}:
                state["action_result"] = "unavailable"
            else:
                await self.hass.services.async_call(
                    domain, service[action], {"entity_id": garage["target"]}, blocking=True
                )
                state["action_result"] = "sent"
        except Exception:  # Device failure must not break recognition or retry physical actions.
            state["action_result"] = "failed"
            _LOGGER.exception("OpenPlate garage action failed")
        finally:
            self._garage_busy.discard(key)
            self.notify("state", {"garage_id": key})

    @callback
    def check_departures(self, _now: datetime) -> None:
        current = time.time()
        timeout = int(self.config[CONF_ABSENCE_TIMEOUT])
        for plate, state in self.presence.items():
            if state.present and current - state.last_seen >= timeout:
                state.present = False
                state.motion = None
                for latch in [item for item in self._garage_directions if item[1] == plate]:
                    self._garage_directions.pop(latch)
                data = {
                    "plate": plate,
                    "display_name": self.plates[plate],
                    "registered": True,
                    "device_id": self.config[CONF_DEVICE_ID],
                    "garage_entity_id": self.garages.get(plate),
                }
                self.notify("disappeared", data)
                self.notify("state", data)

    def _expire_nonces(self, now: float) -> None:
        cutoff = now - SIGNATURE_MAX_AGE_SECONDS
        self._nonces = {nonce: seen for nonce, seen in self._nonces.items() if seen >= cutoff}
        self._event_ids = {key: seen for key, seen in self._event_ids.items() if seen >= cutoff}


async def async_setup(hass: HomeAssistant, _config: ConfigType) -> bool:
    """Set up the one-time pairing endpoint before the first config entry exists."""
    async_ensure_pairing_gateway(hass)
    return True


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
    if entry.version < 4:
        hass.config_entries.async_update_entry(entry, version=4)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unloaded:
        webhook.async_unregister(hass, entry.data[CONF_WEBHOOK_ID])
        hass.data[DOMAIN].pop(entry.entry_id)
    return unloaded


async def _async_reload_entry(hass: HomeAssistant, entry: ConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)
