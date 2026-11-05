"""Bounded, memory-only live image storage for authenticated camera messages."""

import base64
import binascii
import io
from datetime import datetime

from PIL import Image


class CameraBuffer:
    def __init__(self) -> None:
        self.image: bytes | None = None
        self.received_at = 0.0
        self.timestamp = 0.0

    def update(self, payload: dict, now: float) -> None:
        allowed = {"schema_version", "event_type", "device_id", "session_id", "timestamp", "jpeg"}
        if set(payload) - allowed:
            raise ValueError("Unexpected camera fields")
        if not isinstance(payload.get("timestamp"), str):
            raise ValueError("Invalid camera timestamp")
        captured = datetime.fromisoformat(payload["timestamp"].replace("Z", "+00:00"))
        if captured.tzinfo is None:
            raise ValueError("Missing timezone")
        stamp = captured.timestamp()
        if abs(now - stamp) > 10 or stamp <= self.timestamp:
            raise ValueError("Stale camera message")
        image = None
        if payload["event_type"] == "camera.frame":
            encoded = payload["jpeg"]
            if not isinstance(encoded, str) or len(encoded) > 220_000:
                raise ValueError("Image too large")
            try:
                image = base64.b64decode(encoded, validate=True)
                with Image.open(io.BytesIO(image)) as decoded:
                    if decoded.format != "JPEG" or not (
                        1 <= decoded.width <= 640 and 1 <= decoded.height <= 640
                    ):
                        raise ValueError("Invalid image dimensions")
                    decoded.verify()
            except (binascii.Error, OSError, SyntaxError, Image.DecompressionBombError) as err:
                raise ValueError("Invalid JPEG") from err
        elif "jpeg" in payload:
            raise ValueError("Unexpected image")
        self.image = image
        self.timestamp = stamp
        self.received_at = now

    def expire(self, now: float) -> bool:
        if self.image is not None and now - self.received_at > 10:
            self.image = None
            return True
        return False
