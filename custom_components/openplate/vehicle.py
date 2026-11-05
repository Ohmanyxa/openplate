"""Strict vehicle verdict boundary; images and descriptors never cross this API."""

import math

STATUSES = ["unknown", "enrollment_required", "confirmed", "match", "mismatch"]


def validate_vehicle(value: object) -> None:
    fields = {"status", "mode", "type", "color", "similarity", "reference_count"}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError("Invalid vehicle metadata")
    if value["status"] not in STATUSES or value["mode"] not in {"guided", "comparison"}:
        raise ValueError("Invalid vehicle status")
    if value["type"] not in {None, "car", "bus", "truck", "van"} or value["color"] not in {
        None,
        "white",
        "gray",
        "yellow",
        "red",
        "green",
        "blue",
        "black",
    }:
        raise ValueError("Invalid vehicle attributes")
    count = value["reference_count"]
    if type(count) is not int or not 0 <= count <= 12:
        raise ValueError("Invalid reference count")
    score = value["similarity"]
    if score is not None and (
        type(score) not in (int, float) or not -1 <= score <= 1 or not math.isfinite(score)
    ):
        raise ValueError("Invalid similarity")
    if value["status"] == "match" and (
        value["mode"] != "comparison" or count < 6 or score is None or score < 0.88
    ):
        raise ValueError("Invalid automatic match")
    if value["status"] == "confirmed" and (value["mode"] != "guided" or count < 1):
        raise ValueError("Invalid manual confirmation")
    if value["status"] in {"confirmed", "match"} and (
        value["type"] is None or value["color"] is None
    ):
        raise ValueError("Missing vehicle attributes")
