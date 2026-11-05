"""Authenticated WebRTC negotiation, bounded relay and camera configuration."""

import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import test_encrypted_device as device_tests
import voluptuous as vol
from homeassistant.exceptions import HomeAssistantError
from test_identity_motion import TestOptionsFlow
from webrtc_models import RTCIceCandidateInit

from custom_components.openplate.camera import (
    OpenPlateCamera,
    OpenPlateRealtimeCamera,
    async_setup_entry,
)
from custom_components.openplate.configuration import mobile_configuration


class RealtimeTests(unittest.IsolatedAsyncioTestCase):
    setUp = device_tests.EncryptedDeviceTests.setUp
    new_manager = device_tests.EncryptedDeviceTests.new_manager
    envelope = device_tests.EncryptedDeviceTests.envelope
    send = device_tests.EncryptedDeviceTests.send
    decrypt_response = device_tests.EncryptedDeviceTests.decrypt_response

    def poll(self, **updates):
        return {
            "schema_version": 1,
            "event_type": "camera.signaling",
            "device_id": self.config["device_id"],
            "session_id": self.manager._session_id,
            "ack": 0,
            "ready": True,
            "messages": [],
            **updates,
        }

    async def exchange(self, payload):
        envelope = self.envelope(payload)
        task = asyncio.create_task(self.send(envelope))
        await asyncio.sleep(0)
        self.manager.realtime._wake.set()
        response = await task
        return response, self.decrypt_response(response, envelope)

    async def test_upgrade_keeps_camera_id_and_legacy_mode_until_new_app_connects(self):
        hass = SimpleNamespace(data={"openplate": {"entry": self.manager}})
        entry = SimpleNamespace(entry_id="entry")
        add = Mock()
        await async_setup_entry(hass, entry, add)
        old = add.call_args.args[0][0]
        self.assertIs(type(old), OpenPlateCamera)
        self.manager.hass = Mock()
        await self.exchange(self.poll(ready=False))
        self.manager.hass.config_entries.async_update_entry.assert_called_once_with(
            self.manager.entry, options={"camera_transport": "webrtc"}
        )
        await async_setup_entry(hass, entry, add)
        new = add.call_args.args[0][0]
        self.assertIs(type(new), OpenPlateRealtimeCamera)
        self.assertEqual(new.unique_id, old.unique_id)
        await self.exchange(self.poll(ready=False))
        self.manager.hass.config_entries.async_update_entry.assert_called_once()

    async def test_offer_answer_and_candidates_use_encrypted_device_channel(self):
        self.manager.config["live_enabled"] = True
        camera = OpenPlateRealtimeCamera(self.manager)
        sink = Mock()
        envelope = self.envelope(self.poll())
        pending = asyncio.create_task(self.send(envelope))
        await asyncio.sleep(0)
        await camera.async_handle_async_webrtc_offer("v=0\r\nexample-offer", "viewer", sink)
        response = await pending
        self.assertNotIn("example-offer", response.text)
        offer = self.decrypt_response(response, envelope)["messages"][0]
        self.assertEqual(offer["type"], "offer")
        self.assertTrue(camera.available)
        self.assertEqual((await self.send(envelope)).status, 409)
        _, reply = await self.exchange(
            self.poll(
                ack=offer["sequence"],
                messages=[
                    {
                        "id": "answer-id",
                        "session_id": "viewer",
                        "type": "answer",
                        "sdp": "v=0-answer",
                    },
                    {
                        "id": "candidate-id",
                        "session_id": "viewer",
                        "type": "candidate",
                        "candidate": {
                            "candidate": "candidate:1 udp 1 192.168.1.2 1234 typ host",
                            "sdpMid": "0",
                            "sdpMLineIndex": 0,
                        },
                    },
                ],
            )
        )
        self.assertTrue(reply["accepted"])
        self.assertEqual(sink.call_args_list[0].args[0].answer, "v=0-answer")
        self.assertEqual(sink.call_args_list[1].args[0].candidate.sdp_mid, "0")
        count = sink.call_count
        await self.exchange(
            self.poll(
                ack=offer["sequence"],
                messages=[
                    {
                        "id": "answer-id",
                        "session_id": "viewer",
                        "type": "answer",
                        "sdp": "v=0-answer",
                    }
                ],
            )
        )
        self.assertEqual(sink.call_count, count)
        await camera.async_on_webrtc_candidate(
            "viewer",
            RTCIceCandidateInit(
                candidate="candidate:2 udp 1 192.168.1.3 1235 typ host", sdp_mid="0"
            ),
        )
        _, reply = await self.exchange(self.poll(ack=offer["sequence"]))
        self.assertEqual(reply["messages"][0]["type"], "candidate")
        self.assertIsNone(self.manager.last_event)
        camera.close_webrtc_session("viewer")
        self.assertFalse(self.manager.realtime.viewers)
        _, reply = await self.exchange(self.poll(ack=offer["sequence"]))
        self.assertEqual(reply["messages"][0]["type"], "close")

    async def test_disabled_camera_and_stale_session_cannot_negotiate(self):
        await self.exchange(self.poll())
        with self.assertRaises(HomeAssistantError):
            self.manager.realtime.offer("viewer", "offer", Mock())
        response, _ = await self.exchange(self.poll(session_id="old-session"))
        self.assertEqual(response.status, 428)
        self.assertFalse(self.manager.realtime.available)

    async def test_phone_loss_reload_and_viewer_limits(self):
        self.manager.config["live_enabled"] = True
        await self.exchange(self.poll())
        relay = self.manager.realtime
        sink = Mock()
        for session_id in ("one", "two"):
            relay.offer(session_id, "offer", sink)
        with self.assertRaises(HomeAssistantError):
            relay.offer("three", "offer", sink)
        with patch(
            "custom_components.openplate.realtime.time.monotonic", return_value=relay.last_poll + 16
        ):
            relay.expire()
        self.assertFalse(relay.available)
        self.assertFalse(relay.viewers)
        self.assertEqual(sink.call_count, 2)
        relay.close_all()
        self.assertLessEqual(len(relay.queue), 256)

    async def test_invalid_messages_are_rejected_before_any_answer_is_applied(self):
        self.manager.config["live_enabled"] = True
        await self.exchange(self.poll())
        sink = Mock()
        self.manager.realtime.offer("viewer", "offer", sink)
        answer = {"id": "answer", "session_id": "viewer", "type": "answer", "sdp": "valid"}
        for updates in (
            {"ack": True},
            {"ack": 999},
            {"ready": "yes"},
            {"messages": [answer, {"type": "cover.open_cover"}]},
            {
                "messages": [
                    answer,
                    {
                        "id": "bad",
                        "session_id": "viewer",
                        "type": "candidate",
                        "candidate": {"candidate": "x" * 4097},
                    },
                ]
            },
        ):
            response, _ = await self.exchange(self.poll(**updates))
            self.assertEqual(response.status, 400)
            sink.assert_not_called()

    async def test_central_live_settings_validate_fps_and_preserve_plate_options(self):
        flow = TestOptionsFlow()
        flow.test_entry = SimpleNamespace(data=self.config, options={"plates": "BTEST1=Car"})
        flow.async_show_form = Mock(side_effect=lambda **kw: kw)
        flow.async_create_entry = Mock(side_effect=lambda **kw: kw)
        form = await flow.async_step_live()
        self.assertEqual(
            form["data_schema"]({}),
            {"live_enabled": False, "live_fps": 24, "live_resolution": "720p"},
        )
        for fps in (12, 15, 24):
            result = await flow.async_step_live(
                {"live_enabled": True, "live_fps": fps, "live_resolution": "480p"}
            )
            self.assertEqual(result["data"]["plates"], "BTEST1=Car")
            config = mobile_configuration({**self.config, **result["data"]})
            self.assertEqual(config["live_camera"]["fps"], fps)
            self.assertIn("camera_webrtc_v1", config["capabilities"])
        with self.assertRaises(vol.Invalid):
            await flow.async_step_live(
                {"live_enabled": True, "live_fps": 120, "live_resolution": "1080p"}
            )
