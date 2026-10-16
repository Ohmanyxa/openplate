"""Adapters for the upstream FastALPR detector and OCR implementations."""

from __future__ import annotations

from collections.abc import Sequence
from statistics import fmean

from fast_alpr.default_detector import DefaultDetector
from fast_alpr.default_ocr import DefaultOCR

from openplate.domain import BoundingBox, Detection, OcrReading
from openplate.ports import Image

DEFAULT_DETECTOR_MODEL = "yolo-v9-t-384-license-plate-end2end"
DEFAULT_OCR_MODEL = "cct-xs-v2-global-model"


class FastAlprDetector:
    def __init__(
        self,
        model_name: str = DEFAULT_DETECTOR_MODEL,
        confidence_threshold: float = 0.4,
        providers: Sequence[str] | None = None,
    ) -> None:
        self._backend = DefaultDetector(
            model_name=model_name,
            conf_thresh=confidence_threshold,
            providers=providers,
        )

    def detect(self, image: Image) -> list[Detection]:
        return [
            Detection(
                box=BoundingBox(
                    item.bounding_box.x1,
                    item.bounding_box.y1,
                    item.bounding_box.x2,
                    item.bounding_box.y2,
                ),
                confidence=float(item.confidence),
                label=str(item.label),
            )
            for item in self._backend.predict(image)
        ]


class FastPlateOcrReader:
    def __init__(
        self,
        model_name: str = DEFAULT_OCR_MODEL,
        providers: Sequence[str] | None = None,
    ) -> None:
        self._backend = DefaultOCR(
            hub_ocr_model=model_name,
            device="cpu" if providers == ["CPUExecutionProvider"] else "auto",
            providers=providers,
        )

    def read(self, crop: Image) -> OcrReading | None:
        result = self._backend.predict(crop)
        if result is None:
            return None
        confidence = result.confidence
        aggregate = (
            fmean(confidence) if isinstance(confidence, list) and confidence else float(confidence)
        )
        return OcrReading(
            text=result.text,
            confidence=aggregate,
            region=result.region,
            region_confidence=result.region_confidence,
        )
