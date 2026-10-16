"""Command-line entry point for the desktop reference pipeline."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from time import perf_counter

import cv2

from openplate.backends.fast_alpr import (
    DEFAULT_DETECTOR_MODEL,
    DEFAULT_OCR_MODEL,
    FastAlprDetector,
    FastPlateOcrReader,
)
from openplate.pipeline import PlatePipeline


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Lokale Kennzeichenerkennung für ein Einzelbild")
    parser.add_argument("image", type=Path, help="Pfad zum Eingabebild")
    parser.add_argument("--output", type=Path, default=Path("output/annotated.jpg"))
    parser.add_argument("--crops-dir", type=Path, default=Path("output/crops"))
    parser.add_argument("--detector-model", default=DEFAULT_DETECTOR_MODEL)
    parser.add_argument("--ocr-model", default=DEFAULT_OCR_MODEL)
    parser.add_argument("--threshold", type=float, default=0.4)
    parser.add_argument(
        "--cpu-only",
        action="store_true",
        help="Nur ONNX Runtime CPUExecutionProvider verwenden",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.image.is_file():
        print(f"Fehler: Eingabebild nicht gefunden: {args.image}", file=sys.stderr)
        return 2
    if not 0.0 <= args.threshold <= 1.0:
        print("Fehler: --threshold muss zwischen 0 und 1 liegen", file=sys.stderr)
        return 2

    providers = ["CPUExecutionProvider"] if args.cpu_only else None
    init_started = perf_counter()
    detector = FastAlprDetector(args.detector_model, args.threshold, providers)
    reader = FastPlateOcrReader(args.ocr_model, providers)
    initialization_ms = (perf_counter() - init_started) * 1000.0

    report = PlatePipeline(detector, reader).process_file(args.image)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.crops_dir.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(args.output), report.annotated_image):
        raise OSError(f"Visualisierung konnte nicht geschrieben werden: {args.output}")
    crop_paths = []
    for index, crop in enumerate(report.crops):
        path = args.crops_dir / f"plate_{index + 1}.jpg"
        if not cv2.imwrite(str(path), crop):
            raise OSError(f"Crop konnte nicht geschrieben werden: {path}")
        crop_paths.append(str(path))

    payload = {
        "input": str(args.image),
        "output": str(args.output),
        "crops": crop_paths,
        "models": {"detector": args.detector_model, "ocr": args.ocr_model},
        "timings_ms": {
            "model_initialization": round(initialization_ms, 3),
            **report.timings.as_dict(),
        },
        "plates": [
            {
                "text": item.ocr.text if item.ocr else None,
                "ocr_confidence": round(item.ocr.confidence, 6) if item.ocr else None,
                "region": item.ocr.region if item.ocr else None,
                "detection_confidence": round(item.detection.confidence, 6),
                "bounding_box": item.detection.box.as_list(),
                "ocr_ms": round(item.ocr_ms, 3),
            }
            for item in report.results
        ],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
