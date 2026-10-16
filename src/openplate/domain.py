"""Backend-independent ALPR domain values."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class BoundingBox:
    """Pixel coordinates using an exclusive lower-right corner."""

    x1: int
    y1: int
    x2: int
    y2: int

    def clamp(self, width: int, height: int) -> BoundingBox:
        return BoundingBox(
            x1=min(max(self.x1, 0), width),
            y1=min(max(self.y1, 0), height),
            x2=min(max(self.x2, 0), width),
            y2=min(max(self.y2, 0), height),
        )

    @property
    def is_empty(self) -> bool:
        return self.x2 <= self.x1 or self.y2 <= self.y1

    def as_list(self) -> list[int]:
        return [self.x1, self.y1, self.x2, self.y2]


@dataclass(frozen=True, slots=True)
class Detection:
    box: BoundingBox
    confidence: float
    label: str = "License Plate"


@dataclass(frozen=True, slots=True)
class OcrReading:
    text: str
    confidence: float
    region: str | None = None
    region_confidence: float | None = None


@dataclass(frozen=True, slots=True)
class PlateResult:
    detection: Detection
    ocr: OcrReading | None
    crop_index: int
    ocr_ms: float
