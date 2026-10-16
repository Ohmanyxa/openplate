# Architecture

## Current reference path

```text
image file
   │
   ▼
PlatePipeline ──► PlateDetector port ──► FastALPR/open-image-models/ONNX Runtime
   │
   ├── clamp boxes and crop original BGR image
   │
   ├────────────► PlateReader port ────► FastALPR/fast-plate-ocr/ONNX Runtime
   │
   ├──► backend-independent PlateResult values
   └──► annotation, crops, JSON and per-stage timings
```

`src/openplate/domain.py` owns values that cross layers. `ports.py` defines the small inference
contracts. `pipeline.py` contains orchestration but no model names or ONNX types. The adapter in
`backends/fast_alpr.py` is the only code aware of FastALPR. The CLI is an outer delivery mechanism.

This boundary lets a later Swift/Core ML or C++/ncnn adapter implement the same conceptual detector
and reader contracts without changing crop, result, validation or event logic. Python protocols are
the Phase 2 reference, not a cross-language ABI.

## Planned layers

- Camera adapters: AVFoundation on iOS/macOS and libcamera/Picamera2 on Raspberry Pi.
- Preprocessing: normalized ROI, orientation transforms, motion and quality gates.
- Inference: replaceable detection and OCR ports; model-specific preprocessing stays in adapters.
- Temporal validation: multiple observations, conflict handling and confidence policy.
- Events: UUID, device identity, timestamp, deduplication and versioned payload.
- Integrations: authenticated transport and external adapters, isolated from inference internals.

The headless runner will own the pipeline lifecycle on Linux. Flutter will consume state through an
application boundary and will not be required for inference.

## Mounted-camera vertical slice

```text
iPhone camera (foreground, black overlay, wake lock)
       │ JPEG over HTTPS + API key
       ▼
local recognition API ──► detection/OCR ──► 3-frame confirmation
       │ confirmed result
       ▼
iPhone ──► local HTTP(S) + AES-GCM/replay protection ──► HA webhook
                                                    │
                       registered-plate match ──────┼─ event entity
                       recently-seen timeout ───────└─ binary sensor
```

The iPhone never receives a Home Assistant administrator token. The recognition API does not manage
registered plates; that policy remains in Home Assistant. QR-based one-time shared keys bootstrap
AES-256-GCM/HKDF-SHA256 protection for pairing, configuration and events even on local HTTP.
Responses bind the request and status; server-session IDs prevent recorded observations crossing
HA restarts. The frame API remains HTTPS. See [the wire specification](docs/ENCRYPTED_TRANSPORT.md).
Plate text can still enter Home Assistant's recorder and needs an
appropriate retention policy.

The current timeout means “not seen by this camera recently,” not “has left the garage.” Reliable
arrival/departure needs calibrated line-crossing direction or another garage occupancy sensor.

## Memory behavior

The input image is decoded once. Each valid high-resolution crop is copied once so it remains stable
when the visualization buffer is mutated. The still-image runner has no queue. A camera runner must
use a bounded latest-frame buffer and explicitly count replaced frames.

