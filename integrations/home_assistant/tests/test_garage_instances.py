import asyncio
import json
import unittest
from datetime import UTC, datetime
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

from test_garages_motion import TestGarageFlow

from custom_components.openplate import OpenPlateManager
from custom_components.openplate.encryption import seal
from custom_components.openplate.garages import movement_status, validate_garage
from custom_components.openplate.sensor import OpenPlateGarageSensor


class GarageInstanceTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.now = datetime.now(UTC).timestamp()
        self.garage = {
            "name": "Main",
            "plates": ["BTEST1"],
            "target": "cover.garage",
            "arrival_direction": "approaching",
            "arrival_action": "open",
            "departure_action": "close",
            "enabled": True,
        }
        self.config = {
            "device_id": "test",
            "plates": "BTEST1=Car",
            "absence_timeout": 30,
            "transport_version": 2,
            "garages": {"main": self.garage},
        }
        self.tasks = []
        self.entry = SimpleNamespace(data=self.config, options={})

        def create_task(hass, coro, name):
            task = asyncio.create_task(coro, name=name)
            self.tasks.append(task)
            return task

        self.entry.async_create_background_task = create_task
        self.hass = Mock()
        self.hass.states.get.return_value = SimpleNamespace(state="closed")
        self.hass.services.async_call = AsyncMock()
        self.manager = OpenPlateManager(self.hass, self.entry)

    def observation(self, direction="approaching", **overrides):
        return {
            "plate": "BTEST1",
            "timestamp": datetime.fromtimestamp(self.now, UTC).isoformat(),
            "confidence": 0.95,
            "observations": 4,
            "motion": {
                "direction": direction,
                "dx": 0,
                "dy": 0,
                "scale_rate": 0.08 if direction == "approaching" else -0.08,
                "samples": 4,
                "span_seconds": 3,
            },
            **overrides,
        }

    async def flush(self):
        if self.tasks:
            await asyncio.gather(*self.tasks)

    async def test_arrival_once_then_departure_and_sensor(self):
        self.manager.process_observation(self.observation(), self.now)
        self.manager.process_observation(self.observation(), self.now + 1)
        await self.flush()
        self.hass.services.async_call.assert_awaited_once_with(
            "cover", "open_cover", {"entity_id": "cover.garage"}, blocking=True
        )
        sensor = OpenPlateGarageSensor(self.manager, "main")
        self.assertEqual(sensor.native_value, "arrival")
        self.assertEqual(sensor.extra_state_attributes["action_result"], "sent")
        self.manager.process_observation(self.observation("receding"), self.now + 2)
        self.assertEqual(sensor.native_value, "departure")
        self.assertEqual(sensor.extra_state_attributes["action_result"], "cooldown")
        await self.flush()
        self.assertEqual(self.hass.services.async_call.await_count, 1)

    async def test_departure_after_cooldown(self):
        self.manager.process_observation(self.observation(), self.now)
        await self.flush()
        self.now += 61
        self.manager.process_observation(self.observation("receding"), self.now)
        await self.flush()
        self.hass.services.async_call.assert_awaited_with(
            "cover", "close_cover", {"entity_id": "cover.garage"}, blocking=True
        )

    async def test_disabled_stale_unconfirmed_unknown_and_legacy_never_actuate(self):
        for overrides, config in [
            ({}, {"enabled": False}),
            ({"timestamp": "2000-01-01T00:00:00+00:00"}, {}),
            ({"observations": 1}, {}),
            ({"confidence": 0.2}, {}),
            ({"plate": "UNKNOWN"}, {}),
            ({"motion": None}, {}),
        ]:
            self.garage.update({"enabled": True, **config})
            manager = OpenPlateManager(self.hass, self.entry)
            manager.process_observation(self.observation(**overrides), self.now)
        self.config["transport_version"] = 1
        manager = OpenPlateManager(self.hass, self.entry)
        manager.process_observation(self.observation(), self.now)
        await self.flush()
        self.hass.services.async_call.assert_not_awaited()

    async def test_inverted_direction_switch_and_failure(self):
        self.garage.update(
            target="switch.light",
            arrival_action="on",
            departure_action="off",
            arrival_direction="receding",
        )
        manager = OpenPlateManager(self.hass, self.entry)
        manager.process_observation(self.observation("receding"), self.now)
        await self.flush()
        self.hass.services.async_call.assert_awaited_once_with(
            "switch", "turn_on", {"entity_id": "switch.light"}, blocking=True
        )
        self.hass.services.async_call.side_effect = RuntimeError("offline")
        self.now += 61
        manager.process_observation(self.observation(), self.now)
        with self.assertLogs("custom_components.openplate", level="ERROR"):
            await self.flush()
        self.assertEqual(manager.garage_states["main"]["action_result"], "failed")

    def test_policy_rejects_mismatched_actions_and_fake_size_direction(self):
        with self.assertRaises(ValueError):
            validate_garage({**self.garage, "target": "switch.relay"}, {"BTEST1": "Car"})
        motion = self.observation()["motion"]
        self.assertIsNone(movement_status({**motion, "scale_rate": -0.1}, "approaching"))
        self.assertIsNone(movement_status({**motion, "samples": 1}, "approaching"))

    async def test_create_edit_delete_and_validation(self):
        flow = TestGarageFlow()
        flow.test_entry = self.entry
        flow.hass = self.hass
        flow.async_show_form = Mock(side_effect=lambda **kwargs: kwargs)
        flow.async_create_entry = Mock(side_effect=lambda **kwargs: kwargs)
        result = await flow.async_step_garage_instances({"garage_id": "new"})
        self.assertEqual(result["step_id"], "garage_instance")
        created = await flow.async_step_garage_instance(self.garage)
        self.assertEqual(len(created["data"]["garages"]), 2)
        result = await flow.async_step_garage_instance({**self.garage, "target": "light.x"})
        self.assertIn("base", result["errors"])
        await flow.async_step_garage_instances({"garage_id": "main"})
        deleted = await flow.async_step_garage_instance({"remove": True})
        self.assertNotIn("main", deleted["data"]["garages"])

    async def test_encrypted_endpoint_controls_only_server_configured_target_once(self):
        self.config.update(secret="s" * 43, webhook_id="hook")
        manager = OpenPlateManager(self.hass, self.entry)
        payload = {
            **self.observation(),
            "schema_version": 1,
            "event_type": "plate.observed",
            "device_id": "test",
            "event_id": "event-1",
            "session_id": manager._session_id,
        }

        async def send(value):
            body = json.dumps(value).encode()
            request = AsyncMock(content_length=len(body))
            request.read.return_value = body
            return await manager.handle_webhook(self.hass, "hook", request)

        self.assertEqual((await send(payload)).status, 426)
        forged_target = seal({**payload, "target": "cover.other"}, "s" * 43, "device/request/hook")
        self.assertEqual((await send(forged_target)).status, 400)
        wrong_session = seal({**payload, "session_id": "other"}, "s" * 43, "device/request/hook")
        self.assertEqual((await send(wrong_session)).status, 428)
        envelope = seal(payload, "s" * 43, "device/request/hook")
        self.assertEqual((await send(envelope)).status, 200)
        self.assertEqual((await send(envelope)).status, 409)
        self.assertEqual((await send(seal(payload, "s" * 43, "device/request/hook"))).status, 200)
        await self.flush()
        self.hass.services.async_call.assert_awaited_once_with(
            "cover", "open_cover", {"entity_id": "cover.garage"}, blocking=True
        )

    async def test_absence_does_not_close_and_unavailable_is_not_retried(self):
        self.hass.states.get.return_value = SimpleNamespace(state="unavailable")
        self.manager.process_observation(self.observation(), self.now)
        await self.flush()
        self.assertEqual(self.manager.garage_states["main"]["action_result"], "unavailable")
        self.manager.presence["BTEST1"].last_seen = 0
        self.manager.check_departures(datetime.now(UTC))
        await self.flush()
        self.hass.services.async_call.assert_not_awaited()
