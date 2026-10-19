"""Strict metadata boundary: direction is an estimate, never authorization."""

import math


def movement_status(motion: object) -> str:
    """Growing/shrinking plate size determines camera-relative direction."""
    try:
        validate_motion(motion)
    except (ValueError, TypeError):
        return "unknown"
    direction = motion["direction"]
    rate = motion["scale_rate"]
    if direction == "approaching" and rate > 0.04:
        return "arrival"
    if direction == "receding" and rate < -0.04:
        return "departure"
    if direction == "stationary" and abs(rate) < 0.015:
        return "stationary"
    return "unknown"


def validate_motion(value: object) -> None:
    fields = {"direction", "dx", "dy", "scale_rate", "samples", "span_seconds"}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError("Invalid motion fields")
    if not isinstance(value["direction"], str) or value["direction"] not in {
        "unknown",
        "stationary",
        "approaching",
        "receding",
    }:
        raise ValueError("Invalid direction")
    if type(value["samples"]) is not int or not 0 <= value["samples"] <= 20:
        raise ValueError("Invalid sample count")
    span = value["span_seconds"]
    if type(span) not in (int, float) or not 0 <= span <= 10 or not math.isfinite(span):
        raise ValueError("Invalid time span")
    for key in ("dx", "dy", "scale_rate"):
        number = value[key]
        if value["direction"] == "unknown" and number is None:
            continue
        if type(number) not in (int, float) or abs(number) > 5 or not math.isfinite(number):
            raise ValueError("Invalid motion vector")
    if value["direction"] != "unknown" and (value["samples"] < 4 or span < 2):
        raise ValueError("Insufficient motion evidence")
