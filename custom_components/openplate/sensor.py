"""Last recognition sensor."""

from homeassistant.components.sensor import SensorEntity

from .const import CONF_DEVICE_ID, CONF_WEBHOOK_ID
from .entity import OpenPlateEntity


async def async_setup_entry(hass, entry, async_add_entities) -> None:  # type: ignore[no-untyped-def]
    from .const import DOMAIN

    manager = hass.data[DOMAIN][entry.entry_id]
    async_add_entities(
        [
            OpenPlateLastPlateSensor(manager),
            *(OpenPlateGarageSensor(manager, key) for key in manager.garage_instances),
        ]
    )


class OpenPlateGarageSensor(OpenPlateEntity, SensorEntity):
    """Last confirmed travel direction; not the physical door position."""

    _attr_icon = "mdi:garage"
    _attr_device_class = "enum"
    _attr_options = ["unknown", "arrival", "departure"]

    def __init__(self, manager, key) -> None:  # type: ignore[no-untyped-def]
        super().__init__(manager)
        self.key = key
        self._attr_name = f"{manager.garage_instances[key]['name']} movement"
        self._attr_unique_id = f"{manager.config[CONF_DEVICE_ID]}_garage_{key}"

    @property
    def native_value(self):  # type: ignore[no-untyped-def]
        return self.manager.garage_states[self.key]["status"]

    @property
    def extra_state_attributes(self):  # type: ignore[no-untyped-def]
        garage = self.manager.garage_instances[self.key]
        return {
            **self.manager.garage_states[self.key],
            "target": garage["target"],
            "direct_control_enabled": garage["enabled"],
        }


class OpenPlateLastPlateSensor(OpenPlateEntity, SensorEntity):
    _attr_name = "Last plate"
    _attr_icon = "mdi:car-search"

    def __init__(self, manager) -> None:  # type: ignore[no-untyped-def]
        super().__init__(manager)
        device_id = manager.config[CONF_DEVICE_ID]
        self._attr_unique_id = f"{device_id}_last_plate"

    @property
    def native_value(self):  # type: ignore[no-untyped-def]
        return self.manager.last_event["plate"] if self.manager.last_event else None

    @property
    def extra_state_attributes(self):  # type: ignore[no-untyped-def]
        event = self.manager.last_event or {}
        return {
            "registered": event.get("registered"),
            "display_name": event.get("display_name"),
            "confidence": event.get("confidence"),
            "observations": event.get("observations"),
            "garage_entity_id": event.get("garage_entity_id"),
            "motion": event.get("motion"),
            "webhook_path": f"/api/webhook/{self.manager.entry.data[CONF_WEBHOOK_ID]}",
        }
