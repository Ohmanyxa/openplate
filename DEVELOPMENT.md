# Development

## Environment

The project uses Python 3.10–3.13. Python 3.12 is the recommended common denominator for macOS and
64-bit Raspberry Pi OS. Flutter/Dart are reserved for the shared application in the next phase.

```bash
uv sync --extra dev --python 3.12
uv run ruff check .
uv run pytest -q
```

`uv.lock` pins the full reference environment. Do not commit downloaded models or generated output.
Upstream stores models under `~/.cache/open-image-models` and `~/.cache/fast-plate-ocr`.

## Adding a backend

Implement `PlateDetector.detect` and/or `PlateReader.read` from `src/openplate/ports.py`, map results
to the domain dataclasses, then construct `PlatePipeline` with those adapters. Keep resizing,
normalization and output decoding inside the adapter that owns the model contract.

Tests use fake adapters so orchestration, box clipping and crop behavior do not require model downloads.
An integration smoke test is intentionally a separate manual command because it downloads versioned
model assets and its recognition quality depends on the fixture.

## iOS client

```bash
cd apps/openplate_mobile
flutter analyze
flutter test
flutter build ios --debug --no-codesign
open ios/Runner.xcworkspace
```

Camera capture cannot be tested in the simulator. Select the iPhone 12 mini and a development team in
Xcode, then run on the device. The app must stay in the foreground; Guided Access is recommended for a
mounted installation.

