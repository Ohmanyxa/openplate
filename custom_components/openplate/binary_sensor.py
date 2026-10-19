"""Recently-seen sensor for every configured plate."""

from homeassistant.components.binary_sensor import BinarySensorEntity

from .const import CONF_DEVICE_ID, DOMAIN
from .entity import OpenPlateEntity


async def async_setup_entry(hass, entry, async_add_entities) -> None:  # type: ignore[no-untyped-def]
    manager = hass.data[DOMAIN][entry.entry_id]
    async_add_entities(OpenPlatePresenceSensor(manager, plate) for plate in manager.plates)


class OpenPlatePresenceSensor(OpenPlateEntity, BinarySensorEntity):
    _attr_icon = "mdi:garage-variant"

    def __init__(self, manager, plate: str) -> None:  # type: ignore[no-untyped-def]
        super().__init__(manager)
        self.plate = plate
        self._attr_name = f"{plate} detected"
        self._attr_unique_id = f"{manager.config[CONF_DEVICE_ID]}_{plate}_present"

    @property
    def is_on(self) -> bool:
        return self.manager.presence[self.plate].present

    @property
    def extra_state_attributes(self):  # type: ignore[no-untyped-def]
        motion = self.manager.presence[self.plate].motion
        return {
            "plate": self.plate,
            "display_name": self.manager.plates[self.plate],
            "motion": motion,
            "direction": self.manager.presence[self.plate].direction,
        }
