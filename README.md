# OpenPlate

OpenPlate is an offline-first, modular ALPR project. This first increment is a working macOS/Linux
reference pipeline for still images: it loads an image, detects plates, crops them from the original
resolution, runs OCR, prints structured results and timings, and writes an annotated image plus every
plate crop.

The repository also contains the first mounted-camera vertical slice:

- `apps/openplate_mobile`: Flutter/iOS camera client with foreground monitoring and black screen.
- `openplate-server`: authenticated local frame-recognition API with temporal confirmation.
- `custom_components/openplate`: HACS-compatible signed webhook integration and HA entities.

## Quick start

Requirements: Python 3.10–3.13 and [uv](https://docs.astral.sh/uv/). The first invocation downloads
the two ONNX models into the upstream user caches and therefore needs network access. Inference after
that is local.

```bash
uv sync --extra dev --python 3.12
uv run openplate path/to/image.jpg --cpu-only
```

Start the development recognition API with a TLS certificate trusted by the iPhone:

```bash
export OPENPLATE_API_KEY='replace-with-a-long-random-value'
uv run openplate-server --host 0.0.0.0 --port 8844 \
  --ssl-certfile /path/to/fullchain.pem --ssl-keyfile /path/to/privkey.pem
```

The mounted iPhone client accepts HTTPS endpoints only. See
[the Home Assistant setup guide](integrations/home_assistant/README.md) for the complete flow.

## Home Assistant

In HACS, open **Custom repositories**, add `https://github.com/Ohmanyxa/openplate` as category
**Integration**, install OpenPlate, restart Home Assistant and add it under
**Settings → Devices & services**. Releases are the supported installation source; the default branch
is development code.

Adding OpenPlate opens the QR pairing code directly when Home Assistant knows its HTTPS address.
Otherwise, only that address is requested. On the iPhone, tap **iPhone per QR-Code koppeln**, scan,
then confirm the QR screen in Home Assistant. Device identity and keys are generated automatically;
server settings and registered plates are not required for pairing.

Under **Configure**, manage plates or select **Configure recognition server** to enter the local
recognition server HTTPS URL and API key. While open, the paired app retrieves these settings
automatically within about 15 seconds, without another scan. It shows a waiting state until recognition
is configured. The integration does not install or start the recognition server itself.

QR tokens are random, single-use and valid for at most ten minutes. Pairing and authenticated
configuration refresh use HTTPS; iPhone secrets are kept in Keychain.

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

The still-image CLI transmits nothing. The mounted-camera client explicitly sends temporary frames to
the configured local recognition server and confirmed plate events to Home Assistant. A matching plate
must never by itself authorize a garage door or other security-sensitive action. Native iOS inference,
ROI calibration, direction detection and Raspberry Pi deployment remain unimplemented.

## License

OpenPlate source is MIT licensed. Third-party source and model artifacts require their own review; see
[MODEL_INTEGRATION.md](MODEL_INTEGRATION.md#licensing-status).

