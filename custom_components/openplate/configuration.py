"""Public device configuration, shared by pairing and authenticated refresh."""

from typing import Any

from .const import (
    CONF_CAPTURE_INTERVAL,
    CONF_DEVICE_ID,
    CONF_HOME_ASSISTANT_URL,
    CONF_LIVE_ENABLED,
    CONF_LIVE_FPS,
    CONF_LIVE_RESOLUTION,
    CONF_SECRET,
    CONF_WEBHOOK_ID,
    DEFAULT_CAPTURE_INTERVAL,
    DEFAULT_LIVE_FPS,
    DEFAULT_LIVE_RESOLUTION,
)
from .pairing import normalize_base_url
from .plates import parse_plates


def mobile_configuration(configuration: dict[str, Any]) -> dict[str, Any]:
    base_url = normalize_base_url(configuration[CONF_HOME_ASSISTANT_URL])
    return {
        "device_id": configuration[CONF_DEVICE_ID],
        "recognition_mode": "on_device",
        "capabilities": ["motion_v1", "vehicle_v1", "camera_jpeg_v1", "camera_webrtc_v1"],
        "live_camera": {
            "enabled": configuration.get(CONF_LIVE_ENABLED, False),
            "fps": configuration.get(CONF_LIVE_FPS, DEFAULT_LIVE_FPS),
            "resolution": configuration.get(CONF_LIVE_RESOLUTION, DEFAULT_LIVE_RESOLUTION),
        },
        "registered_plates": parse_plates(configuration.get("plates", "")),
        # Empty legacy keys keep previously paired apps/config readers compatible.
        "recognition_url": "",
        "recognition_api_key": "",
        "home_assistant_webhook_url": f"{base_url}/api/webhook/{configuration[CONF_WEBHOOK_ID]}",
        "webhook_secret": configuration[CONF_SECRET],
        "capture_interval_seconds": configuration.get(
            CONF_CAPTURE_INTERVAL, DEFAULT_CAPTURE_INTERVAL
        ),
    }
