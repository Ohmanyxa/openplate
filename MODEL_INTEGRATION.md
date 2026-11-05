# Model integration assessment

Review date: 2026-10-15. The repositories were inspected at these revisions:

- [FastALPR `c5a9470`](https://github.com/ankandrew/fast-alpr/tree/c5a94706f175590b2bc09aa86f46182d4c267fae)
- [open-image-models `f22000e`](https://github.com/ankandrew/open-image-models/tree/f22000e02b30642f317cdba7755c0631638b109e)
- [fast-plate-ocr `9ce7a5b`](https://github.com/ankandrew/fast-plate-ocr/tree/9ce7a5b64a939aa421c243b331d42e6bc25ffd44)

## Findings

FastALPR already supplies the required composition and replaceable `BaseDetector`/`BaseOCR`
interfaces. Its current default pair matches the brief. Detection is delegated to open-image-models;
OCR is delegated to fast-plate-ocr. Reusing those implementations avoids duplicating preprocessing,
YOLO postprocessing and OCR decoding.

The detector registry identifies `yolo-v9-t-384-license-plate-end2end` as a single-class YOLO-v9 ONNX
model with a 0.25 registry default threshold. OpenPlate uses 0.4, matching FastALPR's orchestration
default, and exposes it on the CLI. The upstream published validation table reports metrics, but those
are upstream results and are not treated as OpenPlate device benchmarks.

`cct-xs-v2-global-model` is a Compact Convolutional Transformer OCR model with global plate and region
support. The upstream model zoo currently recommends the larger S variant as its general default; this
project intentionally keeps the requested XS variant for the initial efficiency-oriented baseline.

Both model artifacts are ONNX files fetched from GitHub Releases on first construction. The OCR also
fetches a YAML plate configuration. Cache and network behavior therefore belong to provisioning, not
steady-state inference.

The downloaded artifacts were inspected with ONNX Runtime on the reference Mac. The detector accepts
`images` as float32 NCHW `[1, 3, 384, 384]` and returns `output0` as float32 `[batch, 7]`; the upstream
adapter owns resizing, normalization and end-to-end output decoding. The OCR accepts uint8 NHWC
`[batch, 64, 128, 3]` and has two float32 outputs: `plate` `[batch, 10, 37]` and `region`
`[batch, 66]`. These are observed contracts of the downloaded current artifacts, not a promise for
arbitrary replacement models.

## macOS reference

The implemented backend uses ONNX Runtime and CPU inference when `--cpu-only` is supplied. This is the
portable correctness baseline. Initialization/download time is reported separately from processing
time so warm inference is not confused with cold start. Hardware numbers must be collected from real
runs and are not recorded as claims here.

## Implemented iOS pipeline (updated 2026-10-19)

The mounted-camera app uses the pinned YOLO detector above and **PaddleOCR Latin v5 mobile**
for recognition. The original CCT reader and temporary Vision umlaut correction have been replaced
on iOS only; the Python reference retains the original CCT baseline.

Official model publisher: [PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx](https://huggingface.co/PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx),
revision `89d3a50e2c27e2e7cceeab0e944c25c807d5db4f`.
SHA-256: `7888113072263cb471b93f66dd5e2ad70548dc526fa1ace760d0d973dd121498`.
The publisher lists Apache-2.0; [license and provenance](third_party/NOTICE.md) are included.

The exact ONNX was executed on the Mac reference and native iOS simulator using the official
`onnxruntime-objc` 1.30.0 CocoaPod. CPU, two intra-op threads, no Core ML provider enabled.
Input `x`: float32 NCHW [1,3,48,320]; output `fetch_name_0`: [1,40,838].
Upstream preprocessing is BGR, aspect-preserving resize to height 48 with width bounded at 320,
[-1,1] normalization and zero right padding. Decoding is CTC: blank at zero, adjacent duplicates
collapsed, blank-separated repeated digits retained. The exact alphabet has 836 dictionary entries
plus blank and space, including Ä/Ö/Ü and duplicate glyph entries. Unsupported German-plate
characters are rejected instead of silently erased. No plate-list-based umlaut aliases exist.

Swift inference remains local and serial; Dart temporal confirmation still requires three frames
within four seconds before encrypted observations are emitted. Downloads are hash-pinned and cached.
A new OCR file name avoids loading the old cached CCT weights after an app update.

Tests cover tensor preprocessing, CTC decoding with umlauts and repeated digits, native real-model
execution, and a public upstream smoke image. Rendered text is synthetic and not a German-plate
accuracy benchmark. Real iPhone accuracy and thermals remain unmeasured; general text OCR may
behave differently from a plate-specific reader on seals, EU stripes and unusual fonts.
GPU benchmark numbers from upstream projects are not iPhone performance claims.

Observed sensitivity: a synthetic MÜ line on a wide canvas with large empty margins was read
incompletely in the first native run. The rendered fixture now uses tight text bounds plus a
small border, representing the detector crop rather than the full camera view, and all three
MÜ/BÖ/SÄK cases passed. This is a fixture correction, not evidence that wide-crop sensitivity
has been fixed in the model; keep this case in mind during real-image evaluation.

## Vehicle verification (2026-10-20)

The iPhone additionally runs Intel `vehicle-detection-0200` (BGR 256×256),
`vehicle-attributes-recognition-barrier-0039` (BGR 72×72), and original
`vehicle-reid-0001` (RGB 208×208, 512 descriptor values) with local ONNX Runtime.
Type/color complement owner-confirmed ReID references; no plate-driven self-training.
The attribute model's documented front-view bias requires testing rear views carefully.

Source hashes, conversion details and the guided-to-comparison policy are in
[Vehicle verification](docs/VEHICLE_VERIFICATION.md). Converted Intel heads were
numerically compared to original OpenVINO outputs; native tests execute bundled models.
These are correctness checks, not measured false-acceptance or physical thermal results.

## Core ML conversion assessment (future work)

Directly embedding this Python backend is not the target. A Swift adapter should use AVFoundation and
Core ML, with preprocessing and decoding verified against saved ONNX reference tensors.

Core ML Tools' current unified converter documents TensorFlow and PyTorch—not ONNX—as supported source
formats. The old `onnx-coreml` route is frozen. Therefore a reliable plan is to obtain/export the
original PyTorch graphs and convert them to an ML Program, rather than promise direct ONNX conversion.
The iPhone 12 mini supports the iOS 15-era ML Program deployment floor, but operator support, numerical
parity and actual CPU/GPU/Neural Engine placement remain **untested**. The CCT attention graph and YOLO
end-to-end postprocessing must each be converted and compared before the native backend is accepted.

Relevant primary documentation:

- [Core ML supported conversion sources](https://apple.github.io/coremltools/docs-guides/source/target-conversion-formats.html)
- [ML Program format and deployment targets](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html)
- [Core ML image versus multi-array inputs](https://apple.github.io/coremltools/docs-guides/source/image-inputs.html)

## Raspberry Pi assessment

The first headless implementation should keep these ONNX files and use ONNX Runtime on a 64-bit OS,
then measure Pi 4 and Pi 5 independently. Deployment still needs an installation/build check for the
chosen Python and OS image; it has not been tested here.

ncnn is a valid later experiment because it targets ARM, supports explicit memory allocators and has
an ONNX conversion path through pnnx. Conversion success and numerical parity for both exact graphs are
not yet established. Vulkan should not be assumed faster or more stable on a Pi; compare CPU and Vulkan
after producing matching outputs. See the [ncnn project and conversion overview](https://github.com/Tencent/ncnn)
and [Raspberry Pi build notes](https://github.com/Tencent/ncnn/wiki/how-to-build).

## Acceptance work still required

For each native backend, store fixed input tensors and ONNX outputs, compare decoded boxes/text and
raw outputs within documented tolerances, inspect unsupported/fallback operators, and record cold/warm
latency, memory, provider/device selection, thermals and sustained throughput. None of those measurements
may be inferred from upstream desktop/GPU tables.

## Licensing status

All three inspected source repositories contain an MIT license. Their registries download model
weights from GitHub Release assets, but the inspected repository license files and model registries do
not provide a distinct model card or an artifact-specific license statement. MIT coverage of the code
is clear; redistribution rights and training-data provenance for the weights require explicit upstream
confirmation before OpenPlate redistributes them. This implementation downloads rather than vendors
the weights and does not imply that this resolves downstream licensing obligations.

