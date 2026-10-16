from openplate.domain import BoundingBox, Detection, OcrReading, PlateResult
from openplate.temporal import TemporalConfirmation, normalize_plate


def _result(text: str, confidence: float = 0.9) -> PlateResult:
    return PlateResult(
        Detection(BoundingBox(0, 0, 10, 5), 0.8),
        OcrReading(text, confidence),
        0,
        1.0,
    )


def test_normalize_plate() -> None:
    assert normalize_plate(" b-ab 12-3 ") == "BAB123"


def test_temporal_confirmation_emits_only_one_new_event_until_reset() -> None:
    confirmation = TemporalConfirmation(3, window_seconds=4, reset_after_seconds=10)

    assert confirmation.update("camera", (_result("B AB123"),), 0) == []
    assert confirmation.update("camera", (_result("BAB123"),), 1) == []
    third = confirmation.update("camera", (_result("BAB123"),), 2)
    assert third[0].new_event
    assert third[0].observations == 3

    repeated = confirmation.update("camera", (_result("BAB123"),), 3)
    assert not repeated[0].new_event

    assert confirmation.update("camera", (), 14) == []
    assert confirmation.update("camera", (_result("BAB123"),), 15) == []
