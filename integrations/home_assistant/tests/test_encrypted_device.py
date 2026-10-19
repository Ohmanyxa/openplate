"""Exercise encrypted HTTP events, configuration, downgrade and restart replay protection."""

import json
import time
import unittest
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock

from custom_components.openplate import OpenPlateManager
from custom_components.openplate.encryption import seal, unseal


class EncryptedDeviceTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.config = {
            "device_id": "iphone_test",
            "secret": "s" * 43,
            "plates": "BTEST1=Car",
            "home_assistant_url": "http://homeassistant.local:8123",
            "webhook_id": "device-hook",
            "recognition_url": "https://recognition.example.test",
            "recognition_api_key": "server-key",
            "capture_interval": 1,
            "transport_version": 2,
        }
        self.manager = self.new_manager()

    def new_manager(self):
        return OpenPlateManager(None, SimpleNamespace(data=self.config, options={}))

    def envelope(self, payload):
        return seal(payload, self.config["secret"], "device/request/device-hook")

    async def send(self, envelope, manager=None):
        body = json.dumps(envelope).encode()
        request = AsyncMock()
        request.content_length = len(body)
        request.read.return_value = body
        response = await (manager or self.manager).handle_webhook(None, "device-hook", request)
        return response

    def decrypt_response(self, response, envelope):
        return unseal(
            json.loads(response.body),
            self.config["secret"],
            f"device/response/device-hook/{envelope['id']}/{response.status}",
        )

    def observation(self):
        return {
            "schema_version": 1,
            "event_type": "plate.observed",
            "device_id": "iphone_test",
            "session_id": self.manager._session_id,
            "event_id": "unique-event",
            "plate": "BTEST1",
            "confidence": 0.95,
            "observations": 3,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

    async def test_encrypted_configuration_has_no_plaintext_credentials(self):
        envelope = self.envelope(
            {"schema_version": 1, "event_type": "device.configuration", "device_id": "iphone_test"}
        )
        response = await self.send(envelope)
        self.assertEqual(response.status, 200)
        for value in (self.config["secret"], "server-key", "session_id"):
            self.assertNotIn(value, response.text)
        configuration = self.decrypt_response(response, envelope)
        self.assertEqual(configuration["recognition_api_key"], "")
        self.assertEqual(configuration["recognition_mode"], "on_device")
        self.assertEqual(configuration["session_id"], self.manager._session_id)

    async def test_even_authenticated_frame_payloads_are_rejected(self):
        payload = {**self.observation(), "image": "not-allowed"}
        envelope = self.envelope(payload)
        response = await self.send(envelope)
        self.assertEqual(response.status, 400)
        self.assertIsNone(self.manager.last_event)

    async def test_motion_is_metadata_not_permission_to_choose_a_door(self):
        motion = {
            "direction": "approaching",
            "dx": 0.01,
            "dy": 0,
            "scale_rate": 0.08,
            "samples": 4,
            "span_seconds": 3,
        }
        payload = {**self.observation(), "motion": motion, "garage_entity_id": "cover.attacker"}
        self.assertEqual((await self.send(self.envelope(payload))).status, 400)
        payload.pop("garage_entity_id")
        self.assertEqual((await self.send(self.envelope(payload))).status, 200)
        self.assertEqual(self.manager.last_event["motion"], motion)
        self.assertIsNone(self.manager.last_event["garage_entity_id"])
        bad = {**payload, "event_id": "bad-motion", "motion": {**motion, "dx": float("inf")}}
        self.assertEqual((await self.send(self.envelope(bad))).status, 400)

    async def test_valid_events_are_processed_once_and_replay_is_encrypted_rejection(self):
        notifications = []
        self.manager.subscribe(lambda event_type, data: notifications.append(event_type))
        payload = self.observation()
        envelope = self.envelope(payload)
        response = await self.send(envelope)
        self.assertEqual(self.decrypt_response(response, envelope), {"accepted": True})
        self.assertEqual(self.manager.last_event["plate"], "BTEST1")
        self.assertNotIn("session_id", self.manager.last_event)
        replay = await self.send(envelope)
        self.assertEqual(replay.status, 409)
        self.assertEqual(self.decrypt_response(replay, envelope)["error"], "replayed request")
        retry = self.envelope(payload)
        duplicate = await self.send(retry)
        self.assertTrue(self.decrypt_response(duplicate, retry)["duplicate"])
        self.assertEqual(notifications.count("recognized"), 1)

    async def test_restart_rejects_recorded_plate_even_if_replay_cache_is_empty(self):
        envelope = self.envelope(self.observation())
        manager = self.new_manager()
        response = await self.send(envelope, manager)
        self.assertEqual(response.status, 428)
        self.assertEqual(self.decrypt_response(response, envelope)["error"], "session required")
        self.assertIsNone(manager.last_event)

    async def test_plaintext_and_tampered_requests_are_never_processed(self):
        response = await self.send(self.observation())
        self.assertEqual(response.status, 426)
        envelope = self.envelope(self.observation())
        for field, value in (
            ("id", "changed0123456789"),
            ("timestamp", int(time.time()) + 1),
            ("ciphertext", "AAAAAAAAAAAAAAAAAAAAAA"),
        ):
            response = await self.send({**envelope, field: value})
            self.assertEqual(response.status, 401)
        self.assertIsNone(self.manager.last_event)

    async def test_wrong_device_does_not_return_configuration(self):
        envelope = self.envelope(
            {"schema_version": 1, "event_type": "device.configuration", "device_id": "other"}
        )
        response = await self.send(envelope)
        self.assertEqual(response.status, 400)
        self.assertNotIn("recognition_api_key", self.decrypt_response(response, envelope))

    async def test_fresh_envelope_cannot_refresh_presence_with_stale_observation(self):
        for timestamp in ("2000-01-01T00:00:00+00:00", "2026-01-01T00:00:00"):
            envelope = self.envelope({**self.observation(), "timestamp": timestamp})
            self.assertEqual((await self.send(envelope)).status, 400)
        self.assertFalse(self.manager.presence["BTEST1"].present)

    async def test_encrypted_umlaut_plate_is_distinct_from_ascii_identity(self):
        self.config["plates"] = "MÜAB12=Umlaut\nMUAB12=ASCII"
        self.manager = self.new_manager()
        payload = {**self.observation(), "plate": "MÜAB12"}
        self.assertEqual((await self.send(self.envelope(payload))).status, 200)
        self.assertTrue(self.manager.presence["MÜAB12"].present)
        self.assertFalse(self.manager.presence["MUAB12"].present)
