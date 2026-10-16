"""Backend-independent single-image ALPR orchestration."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from time import perf_counter

import cv2
import numpy as np

from openplate.domain import Detection, PlateResult
from openplate.ports import Image, PlateDetector, PlateReader


@dataclass(frozen=True, slots=True)
class ProcessingTimings:
    image_load_ms: float
    detection_ms: float
    crop_ms: float
    ocr_ms: float
    annotation_ms: float
    total_ms: float

    def as_dict(self) -> dict[str, float]:
        return {
            "image_load_ms": round(self.image_load_ms, 3),
            "detection_ms": round(self.detection_ms, 3),
            "crop_ms": round(self.crop_ms, 3),
            "ocr_ms": round(self.ocr_ms, 3),
            "annotation_ms": round(self.annotation_ms, 3),
            "total_ms": round(self.total_ms, 3),
        }


@dataclass(frozen=True, slots=True)
class ProcessingReport:
    image: Image
    annotated_image: Image
    crops: tuple[Image, ...]
    results: tuple[PlateResult, ...]
    timings: ProcessingTimings


class PlatePipeline:
    """Coordinates image I/O, inference and visualization without owning a model format."""

    def __init__(self, detector: PlateDetector, reader: PlateReader) -> None:
        self._detector = detector
        self._reader = reader

    def process_file(self, image_path: str | Path) -> ProcessingReport:
        total_started = perf_counter()

        load_started = perf_counter()
        image = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        image_load_ms = _elapsed_ms(load_started)
        if image is None:
            raise ValueError(f"Bild konnte nicht geladen werden: {image_path}")

        return self._process_image(image, image_load_ms, total_started)

    def process_image(self, image: Image) -> ProcessingReport:
        """Process an already decoded BGR image without another image copy."""
        if not isinstance(image, np.ndarray) or image.ndim != 3 or image.size == 0:
            raise ValueError("Ungültiges BGR-Bild")
        total_started = perf_counter()
        return self._process_image(image, 0.0, total_started)

    def _process_image(
        self,
        image: Image,
        image_load_ms: float,
        total_started: float,
    ) -> ProcessingReport:

        detection_started = perf_counter()
        detections = self._detector.detect(image)
        detection_ms = _elapsed_ms(detection_started)

        height, width = image.shape[:2]
        crops: list[Image] = []
        valid_detections = []
        crop_started = perf_counter()
        for detection in detections:
            box = detection.box.clamp(width, height)
            if box.is_empty:
                continue
            # Copy once: the crop stays valid independently of later annotation.
            crops.append(image[box.y1 : box.y2, box.x1 : box.x2].copy())
            valid_detections.append(Detection(box, detection.confidence, detection.label))
        crop_ms = _elapsed_ms(crop_started)

        results: list[PlateResult] = []
        ocr_ms = 0.0
        for index, (detection, crop) in enumerate(zip(valid_detections, crops, strict=True)):
            ocr_started = perf_counter()
            reading = self._reader.read(crop)
            current_ocr_ms = _elapsed_ms(ocr_started)
            ocr_ms += current_ocr_ms
            results.append(PlateResult(detection, reading, index, current_ocr_ms))

        annotation_started = perf_counter()
        annotated = self._annotate(image, results)
        annotation_ms = _elapsed_ms(annotation_started)
        timings = ProcessingTimings(
            image_load_ms=image_load_ms,
            detection_ms=detection_ms,
            crop_ms=crop_ms,
            ocr_ms=ocr_ms,
            annotation_ms=annotation_ms,
            total_ms=_elapsed_ms(total_started),
        )
        return ProcessingReport(image, annotated, tuple(crops), tuple(results), timings)

    @staticmethod
    def _annotate(image: Image, results: list[PlateResult]) -> Image:
        output = image.copy()
        for result in results:
            box = result.detection.box.clamp(image.shape[1], image.shape[0])
            cv2.rectangle(output, (box.x1, box.y1), (box.x2, box.y2), (36, 255, 12), 2)
            label = f"plate {result.detection.confidence:.0%}"
            if result.ocr and result.ocr.text:
                label = f"{result.ocr.text} {result.ocr.confidence:.0%}"
            y = box.y1 - 8 if box.y1 >= 24 else min(box.y2 + 22, image.shape[0] - 4)
            cv2.putText(
                output,
                label,
                (max(box.x1, 2), y),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.65,
                (0, 0, 0),
                4,
                cv2.LINE_AA,
            )
            cv2.putText(
                output,
                label,
                (max(box.x1, 2), y),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.65,
                (255, 255, 255),
                1,
                cv2.LINE_AA,
            )
        return output


def _elapsed_ms(started: float) -> float:
    return (perf_counter() - started) * 1000.0
