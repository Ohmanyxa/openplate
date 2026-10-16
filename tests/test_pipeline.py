from pathlib import Path

import cv2
import numpy as np

from openplate.domain import BoundingBox, Detection, OcrReading
from openplate.pipeline import PlatePipeline


class FakeDetector:
    def detect(self, image: np.ndarray) -> list[Detection]:
        assert image.shape == (60, 100, 3)
        return [
            Detection(BoundingBox(-10, 10, 70, 50), 0.9),
            Detection(BoundingBox(50, 20, 40, 30), 0.8),
        ]


class FakeReader:
    def read(self, crop: np.ndarray) -> OcrReading:
        assert crop.shape == (40, 70, 3)
        return OcrReading("BTEST1", 0.95)


def test_pipeline_crops_reads_and_annotates(tmp_path: Path) -> None:
    source = tmp_path / "source.png"
    assert cv2.imwrite(str(source), np.zeros((60, 100, 3), dtype=np.uint8))

    report = PlatePipeline(FakeDetector(), FakeReader()).process_file(source)

    assert len(report.crops) == 1
    assert report.results[0].detection.box == BoundingBox(0, 10, 70, 50)
    assert report.results[0].ocr is not None
    assert report.results[0].ocr.text == "BTEST1"
    assert report.timings.total_ms >= 0
    assert np.any(report.annotated_image != report.image)


def test_pipeline_rejects_unreadable_image(tmp_path: Path) -> None:
    invalid = tmp_path / "invalid.jpg"
    invalid.write_text("not an image")

    try:
        PlatePipeline(FakeDetector(), FakeReader()).process_file(invalid)
    except ValueError as error:
        assert "konnte nicht geladen" in str(error)
    else:
        raise AssertionError("ValueError expected")
