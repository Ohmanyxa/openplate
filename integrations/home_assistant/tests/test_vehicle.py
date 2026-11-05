import unittest
from types import SimpleNamespace

from custom_components.openplate import OpenPlateManager
from custom_components.openplate.configuration import mobile_configuration
from custom_components.openplate.sensor import OpenPlateVehicleSensor
from custom_components.openplate.vehicle import validate_vehicle


class VehicleTests(unittest.TestCase):
    def setUp(self):
        self.verdict = {
            "status": "match",
            "mode": "comparison",
            "type": "car",
            "color": "white",
            "similarity": 0.95,
            "reference_count": 6,
        }
        self.config = {
            "device_id": "phone",
            "plates": "MÜAB12=Family",
            "absence_timeout": 30,
            "home_assistant_url": "http://ha.local",
            "webhook_id": "hook",
            "secret": "s" * 43,
        }

    def test_vehicle_boundary_never_accepts_image_descriptor_or_unjustified_match(self):
        validate_vehicle(self.verdict)
        for update in [
            {"similarity": float("nan")},
            {"similarity": True},
            {"similarity": 0.5},
            {"reference_count": 2},
            {"reference_count": True},
            {"mode": "guided"},
            {"type": None},
            {"embedding": [0] * 512},
            {"image": "private"},
            {"preview": "private"},
        ]:
            with self.assertRaises((ValueError, TypeError)):
                validate_vehicle({**self.verdict, **update})
        validate_vehicle(
            {
                **self.verdict,
                "status": "confirmed",
                "mode": "guided",
                "similarity": None,
                "reference_count": 1,
            }
        )

    def test_per_plate_sensor_reports_verdict_then_resets_on_absence(self):
        manager = OpenPlateManager(None, SimpleNamespace(data=self.config, options={}))
        sensor = OpenPlateVehicleSensor(manager, "MÜAB12")
        self.assertEqual(sensor.native_value, "unknown")
        manager.process_observation({"plate": "MÜAB12", "vehicle": self.verdict}, 1)
        self.assertEqual(sensor.native_value, "match")
        self.assertEqual(sensor.extra_state_attributes["similarity"], 0.95)
        manager.check_departures(None)
        self.assertEqual(sensor.native_value, "unknown")
        self.assertIsNone(manager.presence["MÜAB12"].vehicle)

    def test_encrypted_configuration_advertises_exact_registered_identities(self):
        configuration = mobile_configuration(self.config)
        self.assertEqual(configuration["registered_plates"], {"MÜAB12": "Family"})
        self.assertIn("vehicle_v1", configuration["capabilities"])
