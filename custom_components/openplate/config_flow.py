"""UI configuration for OpenPlate."""

from __future__ import annotations

import secrets
from typing import Any

import voluptuous as vol
from homeassistant import config_entries
from homeassistant.data_entry_flow import FlowResult

from .const import (
    CONF_ABSENCE_TIMEOUT,
    CONF_DEVICE_ID,
    CONF_PLATES,
    CONF_SECRET,
    CONF_WEBHOOK_ID,
    DEFAULT_ABSENCE_TIMEOUT,
    DOMAIN,
)


def _schema(defaults: dict[str, Any] | None = None) -> vol.Schema:
    values = defaults or {}
    return vol.Schema(
        {
            vol.Required(CONF_DEVICE_ID, default=values.get(CONF_DEVICE_ID, "iphone_gate")): str,
            vol.Required(CONF_SECRET, default=values.get(CONF_SECRET, "")): str,
            vol.Required(CONF_PLATES, default=values.get(CONF_PLATES, "")): str,
            vol.Required(
                CONF_ABSENCE_TIMEOUT,
                default=values.get(CONF_ABSENCE_TIMEOUT, DEFAULT_ABSENCE_TIMEOUT),
            ): vol.All(vol.Coerce(int), vol.Range(min=10, max=3600)),
        }
    )


class OpenPlateConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Configure one mounted OpenPlate camera."""

    VERSION = 1

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            if len(user_input[CONF_SECRET]) < 32:
                errors[CONF_SECRET] = "secret_too_short"
            else:
                await self.async_set_unique_id(user_input[CONF_DEVICE_ID])
                self._abort_if_unique_id_configured()
                return self.async_create_entry(
                    title=user_input[CONF_DEVICE_ID],
                    data={
                        **user_input,
                        CONF_WEBHOOK_ID: secrets.token_urlsafe(24),
                    },
                )
        return self.async_show_form(step_id="user", data_schema=_schema(user_input), errors=errors)

    @staticmethod
    def async_get_options_flow(
        config_entry: config_entries.ConfigEntry,
    ) -> config_entries.OptionsFlow:
        return OpenPlateOptionsFlow(config_entry)


class OpenPlateOptionsFlow(config_entries.OptionsFlow):
    def __init__(self, config_entry: config_entries.ConfigEntry) -> None:
        self._entry = config_entry

    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> FlowResult:
        current = {**self._entry.data, **self._entry.options}
        errors: dict[str, str] = {}
        if user_input is not None:
            if len(user_input[CONF_SECRET]) < 32:
                errors[CONF_SECRET] = "secret_too_short"
            else:
                return self.async_create_entry(title="", data=user_input)
        return self.async_show_form(
            step_id="init",
            data_schema=_schema(user_input or current),
            errors=errors,
        )
