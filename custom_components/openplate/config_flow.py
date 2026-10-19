"""UI configuration and QR pairing for OpenPlate."""

from __future__ import annotations

import secrets
from typing import Any

import voluptuous as vol
from homeassistant import config_entries
from homeassistant.core import callback
from homeassistant.data_entry_flow import FlowResult
from homeassistant.helpers.network import NoURLAvailableError, get_url
from homeassistant.helpers.selector import (
    EntitySelector,
    EntitySelectorConfig,
    QrCodeSelector,
    QrCodeSelectorConfig,
    QrErrorCorrectionLevel,
    SelectSelector,
    SelectSelectorConfig,
    TextSelector,
    TextSelectorConfig,
)

from .configuration import mobile_configuration
from .const import (
    CONF_ABSENCE_TIMEOUT,
    CONF_CAPTURE_INTERVAL,
    CONF_DEVICE_ID,
    CONF_HOME_ASSISTANT_URL,
    CONF_PLATES,
    CONF_RECOGNITION_API_KEY,
    CONF_RECOGNITION_URL,
    CONF_SECRET,
    CONF_TRANSPORT_VERSION,
    CONF_WEBHOOK_ID,
    DEFAULT_ABSENCE_TIMEOUT,
    DEFAULT_CAPTURE_INTERVAL,
    DOMAIN,
    PAIRING_CODE_LIFETIME_SECONDS,
    PAIRING_WEBHOOK_ID,
)
from .garages import ACTIONS, validate_garage
from .pairing import build_pairing_uri, normalize_base_url
from .pairing_webhook import async_ensure_pairing_gateway
from .plates import parse_plates

_QR_FIELD = "qr_code"


def _plate_selector() -> TextSelector:
    return TextSelector(TextSelectorConfig(multiline=True))


def _setup_schema(defaults: dict[str, Any] | None = None) -> vol.Schema:
    values = defaults or {}
    return vol.Schema(
        {
            vol.Required(
                CONF_HOME_ASSISTANT_URL,
                default=values.get(CONF_HOME_ASSISTANT_URL) or "http://homeassistant.local:8123",
            ): str,
        }
    )


def _qr_schema(pairing_uri: str) -> vol.Schema:
    return vol.Schema(
        {
            vol.Optional(_QR_FIELD): QrCodeSelector(
                QrCodeSelectorConfig(
                    data=pairing_uri,
                    scale=6,
                    error_correction_level=QrErrorCorrectionLevel.QUARTILE,
                )
            )
        }
    )


def _default_home_assistant_url(
    flow: config_entries.ConfigFlow | config_entries.OptionsFlow,
) -> str:
    if flow.hass.config.internal_url:
        try:
            return normalize_base_url(flow.hass.config.internal_url)
        except ValueError:
            pass
    try:
        return normalize_base_url(
            get_url(flow.hass, allow_external=False, allow_cloud=False, prefer_external=False)
        )
    except (NoURLAvailableError, ValueError):
        if flow.hass.config.external_url:
            try:
                return normalize_base_url(flow.hass.config.external_url)
            except ValueError:
                pass
        return ""


def _create_pairing_uri(
    flow: config_entries.ConfigFlow | config_entries.OptionsFlow,
    configuration: dict[str, Any],
) -> str:
    gateway = async_ensure_pairing_gateway(flow.hass)
    offer_id, key, _expires_at = gateway.create_offer(
        mobile_configuration(configuration),
        lifetime_seconds=PAIRING_CODE_LIFETIME_SECONDS,
    )
    return build_pairing_uri(
        home_assistant_url=configuration[CONF_HOME_ASSISTANT_URL],
        pairing_webhook_id=PAIRING_WEBHOOK_ID,
        offer_id=offer_id,
        key=key,
        lifetime_seconds=PAIRING_CODE_LIFETIME_SECONDS,
    )


class OpenPlateConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Configure one mounted OpenPlate camera."""

    VERSION = 4

    def __init__(self) -> None:
        self._pending_data: dict[str, Any] | None = None
        self._pairing_uri: str | None = None

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        errors: dict[str, str] = {}
        if user_input is None:
            known_url = _default_home_assistant_url(self)
            if known_url:
                user_input = {CONF_HOME_ASSISTANT_URL: known_url}
        if user_input is not None:
            try:
                home_assistant_url = normalize_base_url(user_input[CONF_HOME_ASSISTANT_URL])
            except ValueError:
                errors[CONF_HOME_ASSISTANT_URL] = "invalid_ha_url"
            if not errors:
                device_id = f"iphone_{secrets.token_hex(6)}"
                await self.async_set_unique_id(device_id)
                self._abort_if_unique_id_configured()
                secret = secrets.token_urlsafe(32)
                webhook_id = secrets.token_urlsafe(24)
                self._pending_data = {
                    CONF_DEVICE_ID: device_id,
                    CONF_HOME_ASSISTANT_URL: home_assistant_url,
                    CONF_RECOGNITION_URL: "",
                    CONF_RECOGNITION_API_KEY: "",
                    CONF_CAPTURE_INTERVAL: DEFAULT_CAPTURE_INTERVAL,
                    CONF_PLATES: "",
                    CONF_ABSENCE_TIMEOUT: DEFAULT_ABSENCE_TIMEOUT,
                    CONF_SECRET: secret,
                    CONF_TRANSPORT_VERSION: 2,
                    CONF_WEBHOOK_ID: webhook_id,
                }
                self._pairing_uri = _create_pairing_uri(self, self._pending_data)
                return await self.async_step_pairing_qr()

        defaults = dict(user_input or {})
        defaults.setdefault(CONF_HOME_ASSISTANT_URL, _default_home_assistant_url(self))
        return self.async_show_form(
            step_id="user", data_schema=_setup_schema(defaults), errors=errors
        )

    async def async_step_pairing_qr(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        if self._pending_data is None or self._pairing_uri is None:
            return self.async_abort(reason="pairing_expired")
        if user_input is not None:
            return self.async_create_entry(
                title=self._pending_data[CONF_DEVICE_ID], data=self._pending_data
            )
        return self.async_show_form(step_id="pairing_qr", data_schema=_qr_schema(self._pairing_uri))

    @staticmethod
    @callback
    def async_get_options_flow(
        config_entry: config_entries.ConfigEntry,
    ) -> config_entries.OptionsFlow:
        return OpenPlateOptionsFlow()


class OpenPlateOptionsFlow(config_entries.OptionsFlow):
    """Expose focused management screens instead of one large form."""

    def __init__(self) -> None:
        self._garage_plate: str | None = None
        self._garage_id: str | None = None
        self._pending_options: dict[str, Any] | None = None
        self._pairing_uri: str | None = None

    @property
    def _current(self) -> dict[str, Any]:
        return {**self.config_entry.data, **self.config_entry.options}

    def _updated_options(self, updates: dict[str, Any]) -> dict[str, Any]:
        return {**self.config_entry.options, **updates}

    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        return self.async_show_menu(
            step_id="init",
            menu_options=[
                "pairing",
                "plates",
                "garage_instances",
                "garages",
                "recognition",
                "connection",
                "advanced",
            ],
        )

    async def async_step_garage_instances(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        garages = self._current.get("garages", {})
        if user_input is not None:
            selected = user_input.get("garage_id")
            if selected == "new" or selected in garages:
                self._garage_id = secrets.token_hex(8) if selected == "new" else selected
                return await self.async_step_garage_instance()
        return self.async_show_form(
            step_id="garage_instances",
            data_schema=vol.Schema(
                {
                    vol.Required("garage_id"): SelectSelector(
                        SelectSelectorConfig(
                            options=[
                                {"value": "new", "label": "＋ New garage"},
                                *[
                                    {"value": key, "label": garage["name"]}
                                    for key, garage in garages.items()
                                ],
                            ]
                        )
                    )
                }
            ),
        )

    async def async_step_garage_instance(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        if self._garage_id is None:
            return await self.async_step_garage_instances()
        plates = parse_plates(self._current.get(CONF_PLATES, ""))
        garages = dict(self._current.get("garages", {}))
        current = garages.get(self._garage_id, {})
        errors: dict[str, str] = {}
        if user_input is not None:
            if user_input.get("remove", False):
                garages.pop(self._garage_id, None)
            else:
                value = {
                    key: user_input.get(key)
                    for key in (
                        "name",
                        "plates",
                        "target",
                        "arrival_direction",
                        "arrival_action",
                        "departure_action",
                        "enabled",
                    )
                }
                try:
                    validate_garage(value, plates)
                    target = self.hass.states.get(value["target"])
                    if target is None or target.state in {"unknown", "unavailable"}:
                        raise ValueError("target")
                    garages[self._garage_id] = value
                except (ValueError, TypeError):
                    errors["base"] = "invalid_garage_instance"
            if not errors:
                return self.async_create_entry(
                    title="", data=self._updated_options({"garages": garages})
                )
            current = {**current, **user_input}
        schema: dict[Any, Any] = {
            vol.Required("name", default=current.get("name", "Garage")): str,
            vol.Required("plates", default=current.get("plates", [])): SelectSelector(
                SelectSelectorConfig(
                    multiple=True,
                    options=[
                        {"value": plate, "label": f"{name} ({plate})"}
                        for plate, name in plates.items()
                    ],
                )
            ),
            vol.Required(
                "target", **({"default": current["target"]} if current.get("target") else {})
            ): EntitySelector(EntitySelectorConfig(domain=["cover", "switch"])),
            vol.Required(
                "arrival_direction", default=current.get("arrival_direction", "approaching")
            ): SelectSelector(SelectSelectorConfig(options=["approaching", "receding"])),
            vol.Required(
                "arrival_action", default=current.get("arrival_action", "none")
            ): SelectSelector(SelectSelectorConfig(options=sorted(ACTIONS))),
            vol.Required(
                "departure_action", default=current.get("departure_action", "none")
            ): SelectSelector(SelectSelectorConfig(options=sorted(ACTIONS))),
            vol.Required("enabled", default=current.get("enabled", False)): bool,
            vol.Optional("remove", default=False): bool,
        }
        return self.async_show_form(
            step_id="garage_instance", data_schema=vol.Schema(schema), errors=errors
        )

    async def async_step_plates(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        if user_input is not None:
            return self.async_create_entry(title="", data=self._updated_options(user_input))
        return self.async_show_form(
            step_id="plates",
            data_schema=vol.Schema(
                {
                    vol.Optional(
                        CONF_PLATES, default=self._current.get(CONF_PLATES, "")
                    ): _plate_selector()
                }
            ),
        )

    async def async_step_garages(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        plates = parse_plates(self._current.get(CONF_PLATES, ""))
        if not plates:
            return self.async_abort(reason="no_registered_plates")
        errors: dict[str, str] = {}
        if user_input is not None:
            if user_input.get("plate") in plates:
                self._garage_plate = user_input["plate"]
                return await self.async_step_garage()
            errors["plate"] = "unknown_plate"
        return self.async_show_form(
            step_id="garages",
            errors=errors,
            data_schema=vol.Schema(
                {
                    vol.Required("plate"): SelectSelector(
                        SelectSelectorConfig(
                            options=[
                                {"value": plate, "label": f"{name} ({plate})"}
                                for plate, name in plates.items()
                            ]
                        )
                    )
                }
            ),
        )

    async def async_step_garage(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        if self._garage_plate not in parse_plates(self._current.get(CONF_PLATES, "")):
            return await self.async_step_garages()
        assignments = dict(self._current.get("plate_garages", {}))
        errors: dict[str, str] = {}
        if user_input is not None:
            entity = user_input.get("garage_entity_id", "")
            if user_input.get("remove_assignment", False):
                assignments.pop(self._garage_plate, None)
            elif (
                not isinstance(entity, str)
                or not entity.startswith("cover.")
                or self.hass.states.get(entity) is None
            ):
                errors["garage_entity_id"] = "invalid_garage"
            else:
                assignments[self._garage_plate] = entity
            if not errors:
                return self.async_create_entry(
                    title="", data=self._updated_options({"plate_garages": assignments})
                )
        field = vol.Optional(
            "garage_entity_id",
            **(
                {"default": assignments[self._garage_plate]}
                if self._garage_plate in assignments
                else {}
            ),
        )
        return self.async_show_form(
            step_id="garage",
            errors=errors,
            description_placeholders={"plate": self._garage_plate},
            data_schema=vol.Schema(
                {
                    field: EntitySelector(EntitySelectorConfig(domain="cover")),
                    vol.Optional("remove_assignment", default=False): bool,
                }
            ),
        )

    async def async_step_pairing(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        errors: dict[str, str] = {}
        default_url = self._current.get(CONF_HOME_ASSISTANT_URL) or _default_home_assistant_url(
            self
        )
        if user_input is None and default_url:
            user_input = {CONF_HOME_ASSISTANT_URL: default_url}
        if user_input is not None:
            try:
                home_assistant_url = normalize_base_url(user_input[CONF_HOME_ASSISTANT_URL])
            except ValueError:
                errors[CONF_HOME_ASSISTANT_URL] = "invalid_ha_url"
            if not errors:
                secret = secrets.token_urlsafe(32)
                self._pending_options = self._updated_options(
                    {
                        CONF_HOME_ASSISTANT_URL: home_assistant_url,
                        CONF_SECRET: secret,
                        CONF_TRANSPORT_VERSION: 2,
                    }
                )
                configuration = {**self._current, **self._pending_options}
                self._pairing_uri = _create_pairing_uri(self, configuration)
                return await self.async_step_pairing_qr()
        return self.async_show_form(
            step_id="pairing",
            data_schema=_setup_schema(user_input or {CONF_HOME_ASSISTANT_URL: default_url}),
            errors=errors,
        )

    async def async_step_connection(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                url = normalize_base_url(user_input[CONF_HOME_ASSISTANT_URL])
                return self.async_create_entry(
                    title="", data=self._updated_options({CONF_HOME_ASSISTANT_URL: url})
                )
            except ValueError:
                errors[CONF_HOME_ASSISTANT_URL] = "invalid_ha_url"
        return self.async_show_form(
            step_id="connection",
            data_schema=_setup_schema(user_input or self._current),
            errors=errors,
        )

    async def async_step_recognition(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        if user_input is not None:
            return self.async_create_entry(
                title="",
                data=self._updated_options(
                    {CONF_CAPTURE_INTERVAL: user_input[CONF_CAPTURE_INTERVAL]}
                ),
            )
        defaults = {**self._current, **(user_input or {})}
        return self.async_show_form(
            step_id="recognition",
            data_schema=vol.Schema(
                {
                    vol.Required(
                        CONF_CAPTURE_INTERVAL,
                        default=defaults.get(CONF_CAPTURE_INTERVAL, DEFAULT_CAPTURE_INTERVAL),
                    ): vol.All(vol.Coerce(int), vol.Range(min=1, max=60)),
                }
            ),
        )

    async def async_step_pairing_qr(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        if self._pending_options is None or self._pairing_uri is None:
            return self.async_abort(reason="pairing_expired")
        if user_input is not None:
            return self.async_create_entry(title="", data=self._pending_options)
        return self.async_show_form(step_id="pairing_qr", data_schema=_qr_schema(self._pairing_uri))

    async def async_step_advanced(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        if user_input is not None:
            return self.async_create_entry(title="", data=self._updated_options(user_input))
        return self.async_show_form(
            step_id="advanced",
            data_schema=vol.Schema(
                {
                    vol.Required(
                        CONF_ABSENCE_TIMEOUT,
                        default=self._current.get(CONF_ABSENCE_TIMEOUT, DEFAULT_ABSENCE_TIMEOUT),
                    ): vol.All(vol.Coerce(int), vol.Range(min=10, max=3600))
                }
            ),
        )
