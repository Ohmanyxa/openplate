"""Explicit garage policy, separate from recognition and transport."""

import re
from typing import Any

from .motion import validate_motion

ACTIONS = {"none", "open", "close", "on", "off"}


def validate_garage(value: dict[str, Any], plates: dict[str, str]) -> None:
    if not isinstance(value.get("name"), str) or not value["name"].strip():
        raise ValueError("name")
    assigned = value.get("plates")
    if not isinstance(assigned, list) or not assigned or any(p not in plates for p in assigned):
        raise ValueError("plates")
    if value.get("arrival_direction") not in {"approaching", "receding"}:
        raise ValueError("arrival_direction")
    entity = value.get("target", "")
    if not isinstance(entity, str) or not re.fullmatch(r"(cover|switch)\.[a-z0-9_]+", entity):
        raise ValueError("target")
    allowed = {"none", "open", "close"} if entity.startswith("cover.") else {"none", "on", "off"}
    for key in ("arrival_action", "departure_action"):
        if value.get(key) not in allowed:
            raise ValueError(key)
    if type(value.get("enabled")) is not bool:
        raise ValueError("enabled")


def movement_status(motion: object, arrival_direction: str) -> str | None:
    try:
        validate_motion(motion)
    except (ValueError, TypeError):
        return None
    direction = motion["direction"]
    if direction not in {"approaching", "receding"}:
        return None
    # Require actual expansion/contraction, not merely a client direction label.
    rate = motion["scale_rate"]
    if (direction == "approaching" and rate <= 0.04) or (direction == "receding" and rate >= -0.04):
        return None
    return "arrival" if direction == arrival_direction else "departure"
