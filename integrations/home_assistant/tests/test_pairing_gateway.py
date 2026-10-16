"""Run with Home Assistant installed: python -m unittest discover -s this directory."""

import json
import time
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

from custom_components.openplate import OpenPlateManager
from custom_components.openplate.config_flow import OpenPlateConfigFlow, _qr_schema, _setup_schema
from custom_components.openplate.pairing_webhook import PairingGateway
from custom_components.openplate.security import signature_for


class PairingGatewayTests(unittest.IsolatedAsyncioTestCase):
    async def request(self, gateway, payload):
        body = json.dumps(payload).encode()
        request = AsyncMock()
        request.content_length = len(body)
        request.read.return_value = body
        return await gateway.handle_webhook(None, "openplate_pairing", request)

    async def test_credentials_are_returned_only_once(self):
        gateway = PairingGateway()
        configuration = {"webhook_secret": "private", "recognition_api_key": "api-key"}
        token, _ = gateway.create_offer(configuration, lifetime_seconds=600)
        configuration["webhook_secret"] = "changed"
        response = await self.request(gateway, {"token": token})
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(response.body)["webhook_secret"], "private")
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual((await self.request(gateway, {"token": token})).status, 401)

    async def test_expired_and_unknown_tokens_are_rejected(self):
        gateway = PairingGateway()
        with patch("custom_components.openplate.pairing_webhook.time.time", return_value=1000):
            token, _ = gateway.create_offer({}, lifetime_seconds=600)
        with patch("custom_components.openplate.pairing_webhook.time.time", return_value=1600):
            self.assertEqual((await self.request(gateway, {"token": token})).status, 401)
        self.assertEqual((await self.request(gateway, {"token": "unknown"})).status, 401)

    async def test_malformed_requests_do_not_consume_offer(self):
        gateway = PairingGateway()
        gateway.create_offer({}, lifetime_seconds=600)
        for payload in ({}, [], {"token": 123}):
            self.assertEqual((await self.request(gateway, payload)).status, 400)
        self.assertEqual(len(gateway.offers), 1)

    def test_current_home_assistant_accepts_form_selectors(self):
        self.assertIsNotNone(_setup_schema())
        self.assertIsNotNone(_qr_schema("openplate://pair?version=1"))


class PairingFlowTests(unittest.IsolatedAsyncioTestCase):
    def flow(self, external_url=None, internal_url=None):
        flow = OpenPlateConfigFlow()
        flow.hass = SimpleNamespace(
            config=SimpleNamespace(external_url=external_url, internal_url=internal_url)
        )
        flow.async_set_unique_id = AsyncMock()
        flow._abort_if_unique_id_configured = Mock()
        return flow

    async def test_known_https_url_opens_qr_without_technical_form(self):
        flow = self.flow("http://external.invalid", "https://ha.example.test")
        with patch(
            "custom_components.openplate.config_flow._create_pairing_uri",
            return_value="openplate://pair?version=1",
        ):
            result = await flow.async_step_user()
        self.assertEqual(result["step_id"], "pairing_qr")
        self.assertEqual(flow._pending_data["recognition_url"], "")
        self.assertEqual(flow._pending_data["recognition_api_key"], "")
        self.assertTrue(flow._pending_data["device_id"].startswith("iphone_"))
        self.assertGreaterEqual(len(flow._pending_data["secret"]), 32)
        created = await flow.async_step_pairing_qr({})
        self.assertEqual(created["type"], "create_entry")

    async def test_only_ha_url_is_requested_if_unknown(self):
        result = await self.flow().async_step_user()
        self.assertEqual(result["step_id"], "user")
        self.assertEqual({str(key) for key in result["data_schema"].schema}, {"home_assistant_url"})

    async def test_http_does_not_generate_pairing_code(self):
        result = await self.flow().async_step_user({"home_assistant_url": "http://ha.local"})
        self.assertEqual(result["errors"], {"home_assistant_url": "https_required"})


class ConfigurationRefreshTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.config = {
            "device_id": "iphone_test",
            "secret": "private-signing-secret",
            "plates": "",
            "home_assistant_url": "https://ha.example.test",
            "webhook_id": "device-webhook",
            "recognition_url": "https://recognition.example.test",
            "recognition_api_key": "server-api-key",
            "capture_interval": 2,
        }
        self.manager = OpenPlateManager(None, SimpleNamespace(data=self.config, options={}))

    def request(self, *, device_id="iphone_test", secret=None):
        body = json.dumps(
            {"schema_version": 1, "event_type": "device.configuration", "device_id": device_id}
        ).encode()
        timestamp = str(int(time.time()))
        request = AsyncMock()
        request.content_length = len(body)
        request.read.return_value = body
        request.headers = {
            "X-OpenPlate-Timestamp": timestamp,
            "X-OpenPlate-Nonce": "nonce",
            "X-OpenPlate-Signature": signature_for(
                secret or self.config["secret"], timestamp, "nonce", body
            ),
        }
        return request

    async def test_signed_refresh_returns_configuration_without_plate_event(self):
        request = self.request()
        response = await self.manager.handle_webhook(None, "device-webhook", request)
        self.assertEqual(response.status, 200)
        self.assertEqual(json.loads(response.body)["recognition_api_key"], "server-api-key")
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertIsNone(self.manager.last_event)
        replay = await self.manager.handle_webhook(None, "device-webhook", request)
        self.assertEqual(replay.status, 409)

    async def test_invalid_signature_cannot_read_credentials(self):
        response = await self.manager.handle_webhook(
            None, "device-webhook", self.request(secret="wrong")
        )
        self.assertEqual(response.status, 401)
        self.assertNotIn("server-api-key", response.text)

    async def test_wrong_device_cannot_read_credentials(self):
        response = await self.manager.handle_webhook(
            None, "device-webhook", self.request(device_id="other")
        )
        self.assertEqual(response.status, 400)
        self.assertNotIn("server-api-key", response.text)
