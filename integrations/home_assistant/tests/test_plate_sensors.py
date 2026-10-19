"""Per-plate entities and absence of actuator calls, including old saved options."""

import unittest
from datetime import UTC, datetime
from types import SimpleNamespace
from unittest.mock import Mock, patch

from test_garages_motion import TestGarageFlow

from custom_components.openplate import OpenPlateManager, _remove_obsolete_entities
from custom_components.openplate.binary_sensor import OpenPlatePresenceSensor
from custom_components.openplate.motion import movement_status
from custom_components.openplate.sensor import OpenPlateDirectionSensor


class PlateSensorTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.config = {
            "device_id": "camera",
            "plates": "MÜAB123=Car\nBAB12=Other",
            "absence_timeout": 30,
            "garages": {
                "old": {
                    "enabled": True,
                    "target": "cover.garage",
                    "plates": ["MÜAB123"],
                    "arrival_action": "open",
                    "departure_action": "close",
                }
            },
        }
        self.entry = SimpleNamespace(data=self.config, options={}, entry_id="entry")
        self.hass = Mock()
        self.manager = OpenPlateManager(self.hass, self.entry)

    def motion(self, direction="approaching", rate=0.08):
        return {
            "direction": direction,
            "scale_rate": rate,
            "dx": 0,
            "dy": 0,
            "samples": 4,
            "span_seconds": 3,
        }

    def test_presence_directions_and_no_actuator_with_old_enabled_settings(self):
        present = OpenPlatePresenceSensor(self.manager, "MÜAB123")
        direction = OpenPlateDirectionSensor(self.manager, "MÜAB123")
        other = OpenPlatePresenceSensor(self.manager, "BAB12")
        self.assertFalse(present.is_on)
        self.assertEqual(direction.native_value, "unknown")
        events = []
        self.manager.subscribe(lambda kind, data: events.append(kind))
        now = datetime.now(UTC).timestamp()
        for motion, expected in [
            (self.motion(), "arrival"),
            (self.motion(), "arrival"),
            (self.motion("receding", -0.08), "departure"),
            (self.motion("stationary", 0), "stationary"),
            (None, "unknown"),
        ]:
            self.manager.process_observation({"plate": "MÜAB123", "motion": motion}, now)
            self.assertTrue(present.is_on)
            self.assertEqual(direction.native_value, expected)
            self.assertEqual(present.extra_state_attributes["direction"], expected)
        self.assertEqual(events.count("arrival"), 1)
        self.assertEqual(events.count("departure"), 1)
        self.assertFalse(other.is_on)
        self.manager.presence["MÜAB123"].last_seen = now - 31
        self.manager.check_departures(datetime.now(UTC))
        self.assertFalse(present.is_on)
        self.assertEqual(direction.native_value, "unknown")
        self.hass.services.async_call.assert_not_called()

    def test_no_alias_or_direction_from_disappearance(self):
        self.manager.process_observation({"plate": "MUAB123", "motion": self.motion()}, 100)
        self.assertFalse(self.manager.presence["MÜAB123"].present)
        self.assertFalse(self.manager.last_event["registered"])
        self.assertEqual(movement_status({**self.motion(), "scale_rate": -0.08}), "unknown")
        self.assertEqual(movement_status({**self.motion(), "samples": 1}), "unknown")
        self.assertEqual(movement_status(None), "unknown")

    async def test_menu_and_separate_add_edit_delete_fields(self):
        flow = TestGarageFlow()
        flow.test_entry = self.entry
        flow.hass = self.hass
        flow.async_show_form = Mock(side_effect=lambda **kw: kw)
        flow.async_show_menu = Mock(side_effect=lambda **kw: kw)
        flow.async_create_entry = Mock(side_effect=lambda **kw: kw)
        self.assertEqual(
            (await flow.async_step_init())["menu_options"], ["plates", "pairing", "settings"]
        )
        listing = await flow.async_step_plates()
        selector = next(iter(listing["data_schema"].schema.values()))
        self.assertEqual(selector.config["translation_key"], "registered_plate")
        form = await flow.async_step_plates({"plate": "__new__"})
        self.assertEqual(form["step_id"], "plate")
        fields = form["data_schema"]({"plate": "ÖAB12", "display_name": "Third"})
        self.assertEqual(set(fields), {"plate", "display_name", "remove"})
        result = await flow.async_step_plate({"plate": "Ö AB-12", "display_name": "Third"})
        self.assertIn("ÖAB12=Third", result["data"]["plates"].splitlines())
        self.assertEqual(len(result["data"]["plates"].splitlines()), 3)
        duplicate = await flow.async_step_plate({"plate": "MÜAB123", "display_name": "Duplicate"})
        self.assertEqual(duplicate["errors"]["plate"], "duplicate_plate")
        invalid = await flow.async_step_plate({"plate": "BABC12", "display_name": "bad\nname"})
        self.assertIn("display_name", invalid["errors"])
        await flow.async_step_plates({"plate": "MÜAB123"})
        result = await flow.async_step_plate({"plate": "MÜAB123", "display_name": "Renamed"})
        self.assertIn("MÜAB123=Renamed", result["data"]["plates"])
        deleted = await flow.async_step_plate({"remove": True})
        self.assertNotIn("MÜAB123", deleted["data"]["plates"])

    def test_registry_cleanup_retains_plate_ids_and_other_integrations(self):
        entries = [
            SimpleNamespace(platform=platform, unique_id=uid, entity_id=entity)
            for platform, uid, entity in [
                ("openplate", "camera_MÜAB123_present", "binary_sensor.keep"),
                ("openplate", "camera_garage_old", "sensor.old_garage"),
                ("openplate", "camera_REMOVED_direction", "sensor.removed"),
                ("openplate", "camera_last_plate", "sensor.last"),
                ("other", "camera_garage_other", "sensor.other"),
            ]
        ]
        registry = Mock()
        with (
            patch("custom_components.openplate.er.async_get", return_value=registry),
            patch(
                "custom_components.openplate.er.async_entries_for_config_entry",
                return_value=entries,
            ),
        ):
            _remove_obsolete_entities(self.hass, self.entry, self.manager)
        self.assertEqual(
            [call.args[0] for call in registry.async_remove.call_args_list],
            ["sensor.old_garage", "sensor.removed"],
        )
