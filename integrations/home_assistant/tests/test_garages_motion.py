import unittest
from types import SimpleNamespace
from unittest.mock import Mock

from custom_components.openplate import OpenPlateManager
from custom_components.openplate.config_flow import OpenPlateOptionsFlow
from custom_components.openplate.motion import validate_motion
from custom_components.openplate.plates import normalize_plate, parse_plates


class TestGarageFlow(OpenPlateOptionsFlow):
    @property
    def config_entry(self):
        return self.test_entry


class GarageMotionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.config = {
            "device_id": "test",
            "plates": "BTEST1=Car\nMÜAB12=Umlaut",
            "plate_garages": {"BTEST1": "cover.garage", "NOTKNOWN": "cover.other"},
        }

    def test_exact_umlaut_identity_and_server_owned_assignment(self):
        self.assertEqual(normalize_plate("mu\u0308-ab 12"), "MÜAB12")
        self.assertNotEqual(normalize_plate("MÜAB12"), normalize_plate("MUAB12"))
        manager = OpenPlateManager(None, SimpleNamespace(data=self.config, options={}))
        self.assertNotIn("NOTKNOWN", manager.garages)
        manager.process_observation({"plate": "BTEST1"}, 100)
        self.assertEqual(manager.last_event["garage_entity_id"], "cover.garage")
        manager.process_observation({"plate": "OTHER"}, 101)
        self.assertIsNone(manager.last_event["garage_entity_id"])
        self.assertEqual(parse_plates("MÜAB12=One\nMUAB12=Two"), {"MÜAB12": "One", "MUAB12": "Two"})

    async def test_assign_and_remove_cover_without_calling_a_service(self):
        flow = TestGarageFlow()
        flow.test_entry = SimpleNamespace(data=self.config, options={})
        flow.hass = Mock()
        flow.hass.states.get.side_effect = lambda entity: (
            Mock() if entity == "cover.garage" else None
        )
        flow.async_show_form = Mock(side_effect=lambda **kwargs: kwargs)
        flow.async_create_entry = Mock(side_effect=lambda **kwargs: kwargs)
        initial = await flow.async_step_garages()
        self.assertEqual(initial["step_id"], "garages")
        form = await flow.async_step_garages({"plate": "BTEST1"})
        self.assertEqual(form["step_id"], "garage")
        result = await flow.async_step_garage({"garage_entity_id": "cover.garage"})
        self.assertEqual(result["data"]["plate_garages"]["BTEST1"], "cover.garage")
        removed = await flow.async_step_garage({"remove_assignment": True})
        self.assertNotIn("BTEST1", removed["data"]["plate_garages"])
        rejected = await flow.async_step_garage({"garage_entity_id": "switch.dangerous"})
        self.assertIn("garage_entity_id", rejected["errors"])
        flow.hass.services.async_call.assert_not_called()

    def test_motion_bounds_and_finite_numbers(self):
        motion = {
            "direction": "approaching",
            "dx": 0.01,
            "dy": 0,
            "scale_rate": 0.08,
            "samples": 4,
            "span_seconds": 3,
        }
        validate_motion(motion)
        validate_motion(
            {**motion, "direction": "unknown", "dx": None, "dy": None, "scale_rate": None}
        )
        for override in (
            {"dx": float("nan")},
            {"samples": 1},
            {"span_seconds": 0.1},
            {"direction": "open_garage"},
            {"scale_rate": 100},
            {"dx": True},
            {"dx": 10**1000},
            {"span_seconds": 10**1000},
            {"direction": []},
        ):
            with self.assertRaises(ValueError):
                validate_motion({**motion, **override})
