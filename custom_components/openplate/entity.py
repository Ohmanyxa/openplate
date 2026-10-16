"""Shared OpenPlate entity properties."""

from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity import Entity

from .const import CONF_DEVICE_ID, DOMAIN


class OpenPlateEntity(Entity):
    _attr_has_entity_name = True

    def __init__(self, manager) -> None:  # type: ignore[no-untyped-def]
        self.manager = manager
        device_id = manager.config[CONF_DEVICE_ID]
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, device_id)},
            name=f"OpenPlate {device_id}",
            manufacturer="OpenPlate",
            model="Mounted camera",
        )

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(self.manager.subscribe(self._handle_manager_event))

    def _handle_manager_event(self, _event_type, _data) -> None:  # type: ignore[no-untyped-def]
        self.async_write_ha_state()
