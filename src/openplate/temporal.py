"""Small in-memory temporal confirmation for live recognition sessions."""

from __future__ import annotations

import re
from collections import deque
from dataclasses import dataclass

from openplate.domain import PlateResult

_NOT_ALNUM = re.compile(r"[^A-Z0-9]")


def normalize_plate(value: str) -> str:
    return _NOT_ALNUM.sub("", value.upper())


@dataclass(frozen=True, slots=True)
class ConfirmedPlate:
    plate: str
    confidence: float
    observations: int
    new_event: bool


@dataclass(slots=True)
class _Candidate:
    observations: deque[tuple[float, float]]
    last_seen: float
    active: bool = False


class TemporalConfirmation:
    """Confirm a plate after distinct frames and reset it after an absence."""

    def __init__(
        self,
        required_observations: int = 3,
        window_seconds: float = 4.0,
        reset_after_seconds: float = 10.0,
    ) -> None:
        if required_observations < 1:
            raise ValueError("required_observations must be positive")
        self.required_observations = required_observations
        self.window_seconds = window_seconds
        self.reset_after_seconds = reset_after_seconds
        self._candidates: dict[tuple[str, str], _Candidate] = {}

    def update(
        self,
        device_id: str,
        results: tuple[PlateResult, ...],
        now: float,
    ) -> list[ConfirmedPlate]:
        self._expire(now)
        # One observation per normalized plate and input frame.
        observed: dict[str, float] = {}
        for result in results:
            if result.ocr is None:
                continue
            plate = normalize_plate(result.ocr.text)
            if plate:
                observed[plate] = max(observed.get(plate, 0.0), result.ocr.confidence)

        confirmed: list[ConfirmedPlate] = []
        for plate, confidence in observed.items():
            key = (device_id, plate)
            candidate = self._candidates.get(key)
            if candidate is None:
                candidate = _Candidate(deque(), now)
                self._candidates[key] = candidate
            candidate.last_seen = now
            candidate.observations.append((now, confidence))
            cutoff = now - self.window_seconds
            while candidate.observations and candidate.observations[0][0] < cutoff:
                candidate.observations.popleft()

            count = len(candidate.observations)
            if count < self.required_observations:
                continue
            new_event = not candidate.active
            candidate.active = True
            average = sum(value for _, value in candidate.observations) / count
            confirmed.append(ConfirmedPlate(plate, average, count, new_event))
        return confirmed

    def _expire(self, now: float) -> None:
        expired = [
            key
            for key, candidate in self._candidates.items()
            if now - candidate.last_seen > self.reset_after_seconds
        ]
        for key in expired:
            del self._candidates[key]
