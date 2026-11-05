"""Bounded WebRTC signaling relay. Media flows directly between phone and viewer."""

from __future__ import annotations

import asyncio
import time
from collections import deque
from contextlib import suppress
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from homeassistant.exceptions import HomeAssistantError
from webrtc_models import RTCIceCandidateInit

if TYPE_CHECKING:
    from homeassistant.components.camera.webrtc import WebRTCSendMessage


@dataclass
class Viewer:
    send: WebRTCSendMessage
    created: float
    answered: bool = False
    candidates: int = 0


class RealtimeRelay:
    def __init__(self) -> None:
        self.viewers: dict[str, Viewer] = {}
        self.queue: deque[dict[str, Any]] = deque()
        self.sequence = 0
        self.last_poll = 0.0
        self.ready = False
        self._wake = asyncio.Event()
        self._seen: deque[str] = deque(maxlen=256)
        self._polling = False

    @property
    def available(self) -> bool:
        return self.ready and time.monotonic() - self.last_poll < 15

    def _enqueue(self, session_id: str, kind: str, **data: Any) -> None:
        if len(self.queue) >= 256:
            raise HomeAssistantError("Camera signaling queue is full")
        self.sequence += 1
        self.queue.append(
            {"sequence": self.sequence, "session_id": session_id, "type": kind, **data}
        )
        self._wake.set()

    def offer(self, session_id: str, sdp: str, send: WebRTCSendMessage) -> None:
        self.expire()
        if not self.available:
            raise HomeAssistantError("OpenPlate iPhone camera is not ready")
        if not isinstance(sdp, str) or not 1 <= len(sdp) <= 65536:
            raise HomeAssistantError("Invalid camera offer")
        if len(self.viewers) >= 2 or session_id in self.viewers:
            raise HomeAssistantError("At most two camera viewers are supported")
        self._enqueue(session_id, "offer", sdp=sdp)
        self.viewers[session_id] = Viewer(send, time.monotonic())

    def candidate(self, session_id: str, candidate: dict) -> None:
        viewer = self.viewers.get(session_id)
        if viewer is None:
            return
        if viewer.candidates >= 64:
            self.close(session_id, "Too many ICE candidates")
            return
        self._validate_candidate(candidate)
        self._enqueue(session_id, "candidate", candidate=candidate)
        viewer.candidates += 1

    def close(self, session_id: str, error: str | None = None) -> None:
        viewer = self.viewers.pop(session_id, None)
        if viewer is None:
            return
        self.queue = deque(m for m in self.queue if m["session_id"] != session_id)
        if error:
            from homeassistant.components.camera.webrtc import WebRTCError

            viewer.send(WebRTCError("camera_disconnected", error))
        self._enqueue(session_id, "close")

    def close_all(self) -> None:
        for session_id in list(self.viewers):
            self.close(session_id, "OpenPlate camera connection closed")
        self.ready = False
        self._wake.set()

    def expire(self) -> None:
        if self.ready and not self.available:
            self.close_all()
        for session_id, viewer in list(self.viewers.items()):
            if not viewer.answered and time.monotonic() - viewer.created > 30:
                self.close(session_id, "Camera handshake timed out")

    @staticmethod
    def _validate_candidate(value: Any) -> None:
        if not isinstance(value, dict) or set(value) - {
            "candidate",
            "sdpMid",
            "sdpMLineIndex",
            "userFragment",
        }:
            raise ValueError("Invalid ICE candidate")
        if not isinstance(value.get("candidate"), str) or len(value["candidate"]) > 4096:
            raise ValueError("Invalid ICE candidate")
        fragment = value.get("userFragment")
        if fragment is not None and (not isinstance(fragment, str) or len(fragment) > 256):
            raise ValueError("Invalid ICE username fragment")
        mid, index = value.get("sdpMid"), value.get("sdpMLineIndex")
        if mid is not None and (not isinstance(mid, str) or len(mid) > 256):
            raise ValueError("Invalid media ID")
        if index is not None and (type(index) is not int or not 0 <= index <= 32):
            raise ValueError("Invalid media index")

    def _validate_poll(self, payload: dict) -> None:
        allowed = {
            "schema_version",
            "event_type",
            "device_id",
            "session_id",
            "ack",
            "ready",
            "messages",
        }
        if set(payload) - allowed or type(payload.get("ready")) is not bool:
            raise ValueError("Invalid signaling poll")
        ack = payload.get("ack")
        if type(ack) is not int or not 0 <= ack <= self.sequence:
            raise ValueError("Invalid signaling acknowledgement")
        messages = payload.get("messages")
        if not isinstance(messages, list) or len(messages) > 64:
            raise ValueError("Too many camera messages")
        for message in messages:
            if not isinstance(message, dict):
                raise ValueError("Invalid camera message")
            kind = message.get("type")
            field = {"answer": "sdp", "candidate": "candidate", "error": "error"}.get(kind)
            if field is None or set(message) != {"id", "session_id", "type", field}:
                raise ValueError("Invalid camera message fields")
            if any(
                not isinstance(message[k], str) or not 1 <= len(message[k]) <= 64
                for k in ("id", "session_id")
            ):
                raise ValueError("Invalid camera message ID")
            if kind == "candidate":
                self._validate_candidate(message[field])
            elif not isinstance(message[field], str) or not 1 <= len(message[field]) <= (
                65536 if kind == "answer" else 256
            ):
                raise ValueError("Invalid camera message data")

    async def poll(self, payload: dict, enabled: bool) -> dict:
        from homeassistant.components.camera.webrtc import WebRTCAnswer, WebRTCCandidate

        self._validate_poll(payload)
        if self._polling:
            raise ValueError("A signaling poll is already running")
        self._polling = True
        try:
            self.last_poll = time.monotonic()
            self.ready = payload["ready"] and enabled
            if not self.ready:
                self.close_all()
            self.queue = deque(m for m in self.queue if m["sequence"] > payload["ack"])
            for message in payload["messages"]:
                if message["id"] in self._seen:
                    continue
                self._seen.append(message["id"])
                viewer = self.viewers.get(message["session_id"])
                if viewer is None:
                    continue
                if message["type"] == "answer" and not viewer.answered:
                    viewer.send(WebRTCAnswer(message["sdp"]))
                    viewer.answered = True
                elif message["type"] == "candidate":
                    viewer.send(
                        WebRTCCandidate(RTCIceCandidateInit.from_dict(message["candidate"]))
                    )
                elif message["type"] == "error":
                    self.close(message["session_id"], "iPhone could not establish the video stream")
            if not self.queue:
                self._wake.clear()
                with suppress(TimeoutError):
                    await asyncio.wait_for(self._wake.wait(), timeout=1)
            self.expire()
            return {"accepted": True, "messages": list(self.queue)[:64]}
        finally:
            self._polling = False
