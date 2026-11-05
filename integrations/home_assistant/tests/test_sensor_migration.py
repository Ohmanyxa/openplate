"""Drop retired garage configuration while retaining centrally managed recognition."""

import unittest
from copy import deepcopy
from types import SimpleNamespace
from unittest.mock import Mock

from test_identity_motion import TestOptionsFlow

from custom_components.openplate import OpenPlateManager, async_migrate_entry
from custom_components.openplate.configuration import mobile_configuration
from custom_components.openplate.sensor import OpenPlateLastPlateSensor


class SensorMigrationTests(unittest.IsolatedAsyncioTestCase):
    def entry(self, version=4):
        return SimpleNamespace(
            version=version,
            data={
                "device_id": "iphone_test",
                "plates": "MÜAB12=Family",
                "secret": "secret-not-to-rotate",
                "webhook_id": "same-hook",
                "home_assistant_url": "http://ha.local:8123",
                "transport_version": 2,
                "garages": {"old": {"enabled": True, "target": "cover.old"}},
                "plate_garages": {"MÜAB12": "cover.old"},
            },
            options={
                "plates": "MÜAB12=Family\nBAB12=Other",
                "capture_interval": 2,
                "absence_timeout": 45,
                "garages": {"newer": {"enabled": True, "target": "switch.other"}},
                "plate_garages": {"BAB12": "switch.other"},
            },
        )

    async def test_migration_preserves_pairing_plates_and_central_settings(self):
        for version in (1, 3, 4):
            entry = self.entry(version)
            before = deepcopy(entry)
            hass = Mock()
            self.assertTrue(await async_migrate_entry(hass, entry))
            hass.config_entries.async_update_entry.assert_called_once()
            update = hass.config_entries.async_update_entry.call_args.kwargs
            self.assertEqual(update["version"], 5)
            for key in ("data", "options"):
                self.assertEqual(
                    update[key],
                    {k: v for k, v in getattr(before, key).items()
                     if k not in {"garages", "plate_garages"}},
                )
            manager = OpenPlateManager(
                hass, SimpleNamespace(data=update["data"], options=update["options"])
            )
            self.assertEqual(manager.plates, {"MÜAB12": "Family", "BAB12": "Other"})
            sensor = OpenPlateLastPlateSensor(manager)
            self.assertEqual(sensor.unique_id, "iphone_test_last_plate")
            self.assertNotIn("garage_entity_id", sensor.extra_state_attributes)
            configuration = mobile_configuration(manager.config)
            self.assertEqual(configuration["registered_plates"], manager.plates)
            self.assertEqual(configuration["capture_interval_seconds"], 2)
            self.assertEqual(configuration["webhook_secret"], "secret-not-to-rotate")
            self.assertEqual(entry.data, before.data)
            self.assertEqual(entry.options, before.options)

    async def test_migration_is_idempotent_and_rejects_future_schema(self):
        hass = Mock()
        self.assertTrue(await async_migrate_entry(hass, self.entry(5)))
        hass.config_entries.async_update_entry.assert_not_called()
        self.assertFalse(await async_migrate_entry(hass, self.entry(6)))
        hass.config_entries.async_update_entry.assert_not_called()

    async def test_ha_retains_recognition_and_timeout_controls_without_actuator_menu(self):
        flow = TestOptionsFlow()
        flow.test_entry = self.entry(5)
        flow.async_show_menu = Mock(side_effect=lambda **kw: kw)
        flow.async_show_form = Mock(side_effect=lambda **kw: kw)
        flow.async_create_entry = Mock(side_effect=lambda **kw: kw)
        self.assertEqual(
            (await flow.async_step_init())["menu_options"], ["plates", "pairing", "settings"]
        )
        self.assertEqual(
            (await flow.async_step_settings())["menu_options"],
            ["recognition", "live", "connection", "advanced"],
        )
        recognition = await flow.async_step_recognition({"capture_interval": 1})
        self.assertEqual(recognition["data"]["capture_interval"], 1)
        self.assertEqual(recognition["data"]["plates"], flow.test_entry.options["plates"])
        timeout = await flow.async_step_advanced({"absence_timeout": 60})
        self.assertEqual(timeout["data"]["absence_timeout"], 60)
        self.assertEqual(timeout["data"]["plates"], flow.test_entry.options["plates"])
