"""Exact plate identities; never silently equate umlauts with A/O/U."""

import re
import unicodedata


def normalize_plate(value: str) -> str:
    return re.sub(r"[^A-ZÄÖÜ0-9]", "", unicodedata.normalize("NFC", value).upper())


def parse_plates(value: str) -> dict[str, str]:
    plates: dict[str, str] = {}
    for line in value.splitlines():
        plate, separator, name = line.strip().partition("=")
        normalized = normalize_plate(plate)
        if normalized:
            plates[normalized] = name.strip() if separator and name.strip() else normalized
    return plates
