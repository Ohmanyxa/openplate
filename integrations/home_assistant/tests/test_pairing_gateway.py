"""Run with Home Assistant installed: python -m unittest discover -s this directory."""

import json
import unittest
from unittest.mock import AsyncMock, patch

from custom_components.openplate.config_flow import _qr_schema, _setup_schema
from custom_components.openplate.pairing_webhook import PairingGateway


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
