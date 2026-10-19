"""Recognized, appeared and disappeared event entity."""

from homeassistant.components.event import EventEntity

from .const import CONF_DEVICE_ID, DOMAIN
from .entity import OpenPlateEntity


async def async_setup_entry(hass, entry, async_add_entities) -> None:  # type: ignore[no-untyped-def]
    async_add_entities([OpenPlateEventEntity(hass.data[DOMAIN][entry.entry_id])])


class OpenPlateEventEntity(OpenPlateEntity, EventEntity):
    _attr_name = "Plate event"
    _attr_event_types = ["recognized", "appeared", "disappeared", "arrival", "departure"]
    _attr_icon = "mdi:car-connected"

    def __init__(self, manager) -> None:  # type: ignore[no-untyped-def]
        super().__init__(manager)
        self._attr_unique_id = f"{manager.config[CONF_DEVICE_ID]}_plate_event"

    def _handle_manager_event(self, event_type, data) -> None:  # type: ignore[no-untyped-def]
        if event_type in self._attr_event_types:
            self._trigger_event(event_type, data)
        self.async_write_ha_state()
