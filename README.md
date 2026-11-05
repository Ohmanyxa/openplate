# OpenPlate

OpenPlate is an offline-first, modular ALPR project. This first increment is a working macOS/Linux
reference pipeline for still images: it loads an image, detects plates, crops them from the original
resolution, runs OCR, prints structured results and timings, and writes an annotated image plus every
plate crop.

The repository also contains the first mounted-camera vertical slice:

- `apps/openplate_mobile`: Flutter/iOS client with on-device ONNX detection/OCR, local temporal confirmation, live preview and black mode. Frames stay local unless encrypted HA live view is explicitly enabled.
- `openplate-server`: optional development/reference API, not used by the iPhone app or required by HA.
- `custom_components/openplate`: HACS-compatible signed webhook integration and HA entities.

## Quick start

Requirements: Python 3.10–3.13 and [uv](https://docs.astral.sh/uv/). The first invocation downloads
the two ONNX models into the upstream user caches and therefore needs network access. Inference after
that is local.

```bash
uv sync --extra dev --python 3.12
uv run openplate path/to/image.jpg --cpu-only
```

The optional development/reference API can be started separately (the mobile app does not use it):

```bash
export OPENPLATE_API_KEY='replace-with-a-long-random-value'
uv run openplate-server --host 0.0.0.0 --port 8844 \
  --ssl-certfile /path/to/fullchain.pem --ssl-keyfile /path/to/privkey.pem
```

The mobile app uses no recognition server. Its Home Assistant connection supports local HTTP
with application-level authenticated encryption and needs no HA certificates. See
[the Home Assistant setup guide](integrations/home_assistant/README.md) for the complete flow.

## Home Assistant

In HACS, open **Custom repositories**, add `https://github.com/Ohmanyxa/openplate` as category
**Integration**, install OpenPlate, restart Home Assistant and add it under
**Settings → Devices & services**. Releases are the supported installation source; the default branch
is development code.

Adding OpenPlate detects the local Home Assistant address and opens the QR pairing code directly.
If detection fails, confirm or correct the suggested `http://homeassistant.local:8123` address.
On the iPhone, tap **iPhone per QR-Code koppeln**, scan,
then confirm the QR screen in Home Assistant. Device identity and keys are generated automatically;
server settings and registered plates are not required for pairing.

Under **Configure**, manage registered plates or adjust **On-device recognition**. Detection, OCR and
three-frame confirmation run on the iPhone CPU using ONNX Runtime 1.30.0. The first recognition start
downloads about 11 MB of hash-verified models; subsequent inference is offline. iOS 15.1+ is required.
Core ML acceleration is not enabled. No model runs in HA. Optional live view sends encrypted camera images to paired HA.
The paired app retrieves settings automatically within about 15 seconds without another scan.

The optional H.264/WebRTC live camera is configured centrally in HA (enable, 12/15/24 FPS
as a target, 480p/720p). Update both components and use HA's live view; the JPEG thumbnail
is not the video stream. [Setup and limits](docs/REALTIME_VIDEO.md).

With a saved pairing, opening the iPhone app automatically opens the camera and starts local
recognition. HA-enabled live view starts with it; a failed initial HA request does not delay capture.
Before pairing, **Kamera öffnen** still offers a local preview without a recognition server. **Schwarzmodus** hides the app surface
while the camera and any running recognition continue; tap to reveal controls and return to preview.
iOS backgrounding or locking pauses the camera; returning to the foreground resumes it automatically.
Keep the app in the foreground for continuous operation. See [camera controls](apps/openplate_mobile/README.md#live-preview-and-black-mode).

The QR carries a temporary random 256-bit key, valid for one pairing and at most ten minutes.
That key is never sent in a network request. Pairing, configuration and plate events use AES-256-GCM
and HKDF-SHA256, including over local HTTP. iPhone secrets are kept in Keychain. See the
[encrypted transport specification](docs/ENCRYPTED_TRANSPORT.md).

For an upgrade from earlier releases, update both the HA integration and iPhone app, restart HA,
then pair again to rotate the device key and enable encrypted-only transport. HA's web interface
itself is not encrypted by OpenPlate. Open the QR from your trusted HA interface and keep it private.

Outputs default to `output/annotated.jpg` and `output/crops/`. The JSON written to stdout contains the
recognized text, confidences, pixel bounding boxes and measured stage durations. Use `--help` for
model, threshold and output options.

For a reproducible upstream smoke image:

```bash
curl -L https://raw.githubusercontent.com/ankandrew/fast-alpr/c5a94706f175590b2bc09aa86f46182d4c267fae/assets/test_image.png -o /tmp/openplate-test.png
uv run openplate /tmp/openplate-test.png --cpu-only
```

The default models are exactly those requested in `start.md`:

- Detection: `yolo-v9-t-384-license-plate-end2end`
- OCR: `cct-xs-v2-global-model`

## Verification

```bash
uv run ruff check .
uv run pytest
```

Measured values are emitted only from an actual run. No performance number in this repository is a
hardware promise. See [MODEL_INTEGRATION.md](MODEL_INTEGRATION.md) for the source review and platform
assessment, [ARCHITECTURE.md](ARCHITECTURE.md) for component boundaries, and
[DEVELOPMENT.md](DEVELOPMENT.md) for the workflow.

## Privacy and limitations

The still-image CLI transmits nothing. The mounted-camera client processes frames locally and sends
confirmed plate strings and metadata encrypted to Home Assistant. Optional live view additionally sends encrypted images to paired HA. A matching plate
must never by itself authorize a garage door or other security-sensitive action. Core ML acceleration,
ROI calibration and direction detection remain unimplemented. Local iOS CPU inference is implemented;
physical-device German-plate accuracy, temperature and sustained throughput still need measurement.

## License

OpenPlate source is MIT licensed. Third-party source and model artifacts require their own review; see
[MODEL_INTEGRATION.md](MODEL_INTEGRATION.md#licensing-status).

