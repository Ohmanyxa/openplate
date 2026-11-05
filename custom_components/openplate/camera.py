"""Paired iPhone live camera, served through Home Assistant's camera API."""

import time

from homeassistant.components.camera import Camera, CameraEntityFeature
from homeassistant.components.camera.webrtc import WebRTCClientConfiguration
from webrtc_models import RTCConfiguration

from .const import CONF_CAMERA_TRANSPORT, CONF_DEVICE_ID, DOMAIN
from .entity import OpenPlateEntity


async def async_setup_entry(hass, entry, async_add_entities) -> None:
    manager = hass.data[DOMAIN][entry.entry_id]
    entity_type = (
        OpenPlateRealtimeCamera
        if manager.config.get(CONF_CAMERA_TRANSPORT) == "webrtc"
        else OpenPlateCamera
    )
    async_add_entities([entity_type(manager)])


class OpenPlateCamera(OpenPlateEntity, Camera):
    _attr_name = "Live camera"
    _attr_should_poll = False
    _attr_frame_interval = 0.5

    def __init__(self, manager) -> None:
        Camera.__init__(self)
        OpenPlateEntity.__init__(self, manager)
        self._attr_unique_id = f"{manager.config[CONF_DEVICE_ID]}_camera"

    @property
    def available(self) -> bool:
        buffer = self.manager.camera
        return self.manager.realtime.available or (
            buffer.image is not None and time.time() - buffer.received_at <= 10
        )

    async def async_camera_image(self, width=None, height=None) -> bytes | None:
        return self.manager.camera.image if self.available else None


class OpenPlateRealtimeCamera(OpenPlateCamera):
    """Native WebRTC after the paired phone has advertised its support."""

    _attr_supported_features = CameraEntityFeature.STREAM

    async def async_handle_async_webrtc_offer(self, offer_sdp, session_id, send_message) -> None:
        self.manager.realtime.offer(session_id, offer_sdp, send_message)

    async def async_on_webrtc_candidate(self, session_id, candidate) -> None:
        self.manager.realtime.candidate(session_id, candidate.to_dict())

    def close_webrtc_session(self, session_id) -> None:
        self.manager.realtime.close(session_id)

    def _async_get_webrtc_client_configuration(self) -> WebRTCClientConfiguration:
        # The phone uses host candidates. HA may add its configured ICE servers for viewers.
        return WebRTCClientConfiguration(configuration=RTCConfiguration(ice_servers=[]))
