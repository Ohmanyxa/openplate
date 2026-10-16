"""Local-only test harness for the real Dart client; never install in production.

Run with Home Assistant installed, then set OPENPLATE_INTEROP_URL to the printed URL
and run flutter test test/http_interop_test.dart in apps/openplate_mobile.
"""

import asyncio
import json
from types import SimpleNamespace

from aiohttp import web

from custom_components.openplate import OpenPlateManager
from custom_components.openplate.configuration import mobile_configuration
from custom_components.openplate.pairing import build_pairing_uri
from custom_components.openplate.pairing_webhook import PairingGateway


async def main():
    gateway = PairingGateway()
    config = {
        "device_id": "interop_iphone",
        "secret": "test-only-secret-" * 3,
        "plates": "BTEST1=Test",
        "home_assistant_url": "",
        "webhook_id": "interop-device",
        "recognition_url": "",
        "recognition_api_key": "",
        "capture_interval": 1,
        "transport_version": 2,
    }
    manager = OpenPlateManager(None, SimpleNamespace(data=config, options={}))
    recognized = []
    manager.subscribe(lambda kind, data: recognized.append(data) if kind == "recognized" else None)

    async def bootstrap(_request):
        offer_id, key, _ = gateway.create_offer(
            mobile_configuration(manager.config), lifetime_seconds=600
        )
        return web.json_response(
            {
                "qr": build_pairing_uri(
                    home_assistant_url=manager.config["home_assistant_url"],
                    pairing_webhook_id="openplate_pairing",
                    offer_id=offer_id,
                    key=key,
                )
            }
        )

    async def pair(request):
        return await gateway.handle_webhook(None, "openplate_pairing", request)

    async def device(request):
        return await manager.handle_webhook(None, "interop-device", request)

    async def state(_request):
        return web.json_response({"recognized": len(recognized), "last_event": manager.last_event})

    app = web.Application()
    app.router.add_get("/test/bootstrap", bootstrap)
    app.router.add_get("/test/state", state)
    app.router.add_post("/api/webhook/openplate_pairing", pair)
    app.router.add_post("/api/webhook/interop-device", device)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    manager.config["home_assistant_url"] = f"http://127.0.0.1:{port}"
    print(json.dumps({"url": manager.config["home_assistant_url"]}), flush=True)
    try:
        await asyncio.Event().wait()
    finally:
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
