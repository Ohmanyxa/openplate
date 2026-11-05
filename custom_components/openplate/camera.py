"""Paired iPhone live camera, served through Home Assistant's camera API."""

import time

from homeassistant.components.camera import Camera

from .const import CONF_DEVICE_ID, DOMAIN
from .entity import OpenPlateEntity


async def async_setup_entry(hass, entry, async_add_entities) -> None:
    async_add_entities([OpenPlateCamera(hass.data[DOMAIN][entry.entry_id])])


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
        return buffer.image is not None and time.time() - buffer.received_at <= 10

    async def async_camera_image(self, width=None, height=None) -> bytes | None:
        return self.manager.camera.image if self.available else None
