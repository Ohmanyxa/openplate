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
       │ continuous raw BGRA video frames, in device memory only
       ▼
frame admission gate ──► serial native iOS inference worker
       ▼
local ONNX Runtime CPU ──► YOLO detection ──► high-resolution crop ──► CCT OCR
       │ decoded strings, still on device
       ▼
local 3-frame / 4-second confirmation (minimum OCR confidence 0.8)
       │ confirmed plate string + metadata only
       ▼
iPhone ──► local HTTP(S) + AES-GCM/replay protection ──► HA webhook
                                                    │
                       registered-plate match ──────┼─ event entity
                       recently-seen timeout ───────└─ binary sensor
```

The app uses the camera image stream, not periodic still-photo capture. The processing interval
limits admission of video frames, not camera acquisition. Only one frame is processed at a time;
frames arriving while busy are skipped rather than queued. No JPEG encoding, photo files or image
uploads exist in the mobile path. Native preview and black display mode are independent of recognition.
The pinned upstream model artifacts are downloaded once over HTTPS, SHA-256 verified, and cached in
Application Support (excluded from backups). Subsequent inference works offline. ONNX Runtime 1.30.0
executes locally on the iPhone CPU with two intra-op threads; Core ML/Neural Engine acceleration has
not been enabled or measured. Android local inference is not implemented. iOS 15.1+ is required.

The iPhone never receives a Home Assistant administrator token. Registered-plate policy remains in
Home Assistant; the Pi runs no model. QR-based one-time shared keys bootstrap
AES-256-GCM/HKDF-SHA256 protection for pairing, configuration and events even on local HTTP.
Responses bind the request and status; server-session IDs prevent recorded observations crossing
HA restarts. HA accepts only observation fields, never images. Continued confirmed observations
refresh HA presence. Sending runs separately from inference; pending observations are coalesced per
plate and expire after ten seconds so reconnecting does not replay old arrivals.
See [the wire specification](docs/ENCRYPTED_TRANSPORT.md).
Plate text can still enter Home Assistant's recorder and needs an
appropriate retention policy.

The current timeout means “not seen by this camera recently,” not “has left the garage.” Reliable
arrival/departure needs calibrated line-crossing direction or another garage occupancy sensor.

Device-key authentication proves possession of the paired key, not physical camera provenance. A
compromised paired phone/key or a printed/copied plate can still produce an observation. Attestation
and additional access-control factors are future work, not guarantees of the encrypted transport.

## Memory behavior

The input image is decoded once. Each valid high-resolution crop is copied once so it remains stable
when the visualization buffer is mutated. The still-image runner has no queue. A camera runner must
use a bounded latest-frame buffer and explicitly count replaced frames.

