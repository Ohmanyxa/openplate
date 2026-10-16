"""Replaceable inference interfaces used by the shared pipeline."""

from __future__ import annotations

from typing import Protocol

import numpy as np
from numpy.typing import NDArray

from openplate.domain import Detection, OcrReading

Image = NDArray[np.uint8]


class PlateDetector(Protocol):
    def detect(self, image: Image) -> list[Detection]: ...


class PlateReader(Protocol):
    def read(self, crop: Image) -> OcrReading | None: ...
