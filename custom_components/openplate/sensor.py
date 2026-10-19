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
            *(OpenPlateDirectionSensor(manager, plate) for plate in manager.plates),
        ]
    )


class OpenPlateDirectionSensor(OpenPlateEntity, SensorEntity):
    """Camera-relative motion for one registered plate, never a door command."""

    _attr_icon = "mdi:car-arrow-left"
    _attr_device_class = "enum"
    _attr_options = ["unknown", "stationary", "arrival", "departure"]

    def __init__(self, manager, plate: str) -> None:  # type: ignore[no-untyped-def]
        super().__init__(manager)
        self.plate = plate
        self._attr_name = f"{plate} direction"
        self._attr_unique_id = f"{manager.config[CONF_DEVICE_ID]}_{plate}_direction"

    @property
    def native_value(self):  # type: ignore[no-untyped-def]
        state = self.manager.presence[self.plate]
        return state.direction if state.present else "unknown"

    @property
    def extra_state_attributes(self):  # type: ignore[no-untyped-def]
        state = self.manager.presence[self.plate]
        return {
            "plate": self.plate,
            "display_name": self.manager.plates[self.plate],
            "present": state.present,
            "motion": state.motion,
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
