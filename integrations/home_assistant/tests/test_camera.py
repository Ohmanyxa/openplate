"""Encrypted live camera transport, lifecycle, ordering and payload bounds."""

import asyncio
import base64
import io
import time
import unittest
from datetime import datetime, timezone

import test_encrypted_device as device_tests
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
from PIL import Image

from custom_components.openplate.camera import OpenPlateCamera


class CameraTests(unittest.IsolatedAsyncioTestCase):
    setUp = device_tests.EncryptedDeviceTests.setUp
    new_manager = device_tests.EncryptedDeviceTests.new_manager
    envelope = device_tests.EncryptedDeviceTests.envelope
    send = device_tests.EncryptedDeviceTests.send
    decrypt_response = device_tests.EncryptedDeviceTests.decrypt_response

    def frame(self, **changes):
        stream = io.BytesIO()
        Image.new("RGB", (32, 24)).save(stream, format="JPEG")
        return {
            "schema_version": 1,
            "event_type": "camera.frame",
            "device_id": self.config["device_id"],
            "session_id": self.manager._session_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "jpeg": base64.b64encode(stream.getvalue()).decode(),
            **changes,
        }

    async def test_frame_is_memory_only_camera_and_stop_clears_it(self):
        frame = self.frame()
        envelope = self.envelope(frame)
        response = await self.send(envelope)
        self.assertEqual(response.status, 200)
        self.assertTrue(self.decrypt_response(response, envelope)["accepted"])
        camera = OpenPlateCamera(self.manager)
        self.assertTrue(camera.available)
        self.assertEqual(await camera.async_camera_image(), base64.b64decode(frame["jpeg"]))
        self.assertIsNone(self.manager.last_event)
        stopped = self.frame(event_type="camera.stopped")
        stopped.pop("jpeg")
        self.assertEqual((await self.send(self.envelope(stopped))).status, 200)
        self.assertFalse(camera.available)
        self.assertIsNone(await camera.async_camera_image())
        self.assertEqual((await self.send(self.envelope(frame))).status, 400)

    async def test_bad_stale_oversized_and_old_session_frames_rejected(self):
        for changes in (
            {"jpeg": "not-a-jpeg"},
            {"timestamp": None},
            {"jpeg": "A" * 220001},
            {"timestamp": "2000-01-01T00:00:00+00:00"},
            {"timestamp": "2026-11-05T12:00:00"},
            {"extra": "unexpected"},
        ):
            self.assertEqual((await self.send(self.envelope(self.frame(**changes)))).status, 400)
        self.assertEqual(
            (await self.send(self.envelope(self.frame(session_id="old-session")))).status, 428
        )
        self.assertIsNone(self.manager.camera.image)

    async def test_replay_restart_and_expiry(self):
        envelope = self.envelope(self.frame())
        self.assertEqual((await self.send(envelope)).status, 200)
        self.assertEqual((await self.send(envelope)).status, 409)
        self.assertEqual((await self.send(envelope, self.new_manager())).status, 428)
        camera = OpenPlateCamera(self.manager)
        self.manager.camera.received_at = time.time() - 11
        self.assertFalse(camera.available)
        self.assertIsNone(await camera.async_camera_image())
        self.assertTrue(self.manager.camera.expire(time.time()))
        self.assertIsNone(self.manager.camera.image)

    async def test_standard_ha_mjpeg_handler_serves_live_image(self):
        frame = self.frame()
        self.assertEqual((await self.send(self.envelope(frame))).status, 200)
        camera = OpenPlateCamera(self.manager)
        app = web.Application()
        app.router.add_get("/camera", camera.handle_async_mjpeg_stream)
        async with TestClient(TestServer(app)) as client:
            response = await client.get("/camera")
            self.assertEqual(response.status, 200)
            self.assertIn("multipart/x-mixed-replace", response.headers["Content-Type"])
            data = await asyncio.wait_for(response.content.read(4096), timeout=2)
            self.assertIn(b"Content-Type: image/jpeg", data)
            self.assertIn(base64.b64decode(frame["jpeg"]), data)
            self.manager.camera.image = None
            await asyncio.wait_for(response.read(), timeout=2)
