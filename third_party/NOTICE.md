# PaddleOCR Latin recognition model

OpenPlate's iOS app uses PaddlePaddle's `latin_PP-OCRv5_mobile_rec_onnx`,
published with Apache-2.0 metadata by PaddlePaddle. It is downloaded separately,
not included in the source tree. Keep the accompanying license with distributions.

- Publisher: https://huggingface.co/PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx
- Revision: `89d3a50e2c27e2e7cceeab0e944c25c807d5db4f`
- File: `inference.onnx` (8,042,023 bytes)
- SHA-256: `7888113072263cb471b93f66dd5e2ad70548dc526fa1ace760d0d973dd121498`
- Ordered alphabet: `PostProcess.character_dict` in the same revision's `inference.yml`.
- Source project: https://github.com/PaddlePaddle/PaddleOCR
- Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.
- License: [Apache License 2.0](PaddleOCR-LICENSE).

OpenPlate implements its own bounded Swift preprocessing/CTC decoding following
the upstream BGR/CHW normalization, padding and blank/repeat conventions. The
model and ordered alphabet are unmodified. The alphabet includes duplicate glyph
entries: do not sort or deduplicate its class indices.

This is a multilingual general text recognizer, not a verified German-license-plate
accuracy guarantee. It replaces the former ASCII-only CCT reader and Vision
post-correction in the iPhone app; YOLO detection remains unchanged.

## Vehicle recognition assets

The app also bundles exported Open Model Zoo weights:

- `vehicle-detection-0200` and `vehicle-attributes-recognition-barrier-0039`:
  Intel Corporation, Apache-2.0. https://github.com/openvinotoolkit/open_model_zoo/tree/master/models/intel
- `vehicle-reid-0001` / OSNet: MIT, Copyright (c) 2018 Kaiyang Zhou.
  https://github.com/openvinotoolkit/open_model_zoo/tree/master/models/public/vehicle-reid-0001

Original downloads are SHA-384 checked by `scripts/prepare_vehicle_models.py`.
Intel IR graphs were converted after constant folding. DetectionOutput was removed
and raw SSD heads exposed; OpenPlate implements decode/NMS. ReID weights are unmodified.
The app includes `Intel-OpenModelZoo-LICENSE` and `Vehicle-ReID-LICENSE` in its assets
and license screen. See [vehicle verification](../docs/VEHICLE_VERIFICATION.md) for
checks and limitations. These models do not provide an anti-spoofing/liveness guarantee.
