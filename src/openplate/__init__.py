"""OpenPlate reference pipeline."""

from openplate.domain import BoundingBox, Detection, PlateResult
from openplate.pipeline import PlatePipeline, ProcessingReport

__all__ = [
    "BoundingBox",
    "Detection",
    "PlatePipeline",
    "PlateResult",
    "ProcessingReport",
]
