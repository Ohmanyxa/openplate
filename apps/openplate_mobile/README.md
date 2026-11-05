# OpenPlate Mobile

Flutter/iOS foreground camera client for a mounted OpenPlate camera.

## Pair with Home Assistant

1. Add OpenPlate in Home Assistant, or select **Configure → Pair an iPhone** for an existing entry.
2. Home Assistant detects its local address and shows the QR. If needed, confirm or correct the suggested
   `http://homeassistant.local:8123` address. No HA certificates are required.
3. In this app, tap **iPhone per QR-Code koppeln** (or open connection management to pair again).
4. Scan the code before it expires, then confirm the QR screen in Home Assistant.
5. Configure registered plates in Home Assistant. No recognition server or API key is required.
6. The open app retrieves processing settings automatically within about 15 seconds, also while the
   camera screen is open. No manual configuration or second QR scan is needed on the iPhone.

## Live preview and black mode

Tap **Kamera öffnen** to align the camera. The local live preview works even before pairing or before
configuring a recognition server. It neither takes still photos nor uploads frames by itself. HA
connection and recognition status are displayed separately; saved pairing data alone is not shown as
a verified live connection.

With a saved pairing, app launch automatically opens the camera and starts recognition.
After temporarily stopping recognition, **Erkennung starten** resumes it manually. The first start downloads about 11 MB of pinned models over
HTTPS and verifies their SHA-256 hashes. Subsequent recognition works offline on the iPhone CPU via
ONNX Runtime 1.30.0, not yet Core ML/Neural Engine. iOS 15.1+ is required.
By default camera frames stay local; confirmed plate strings and metadata go encrypted to HA.
Optional HA live view additionally sends encrypted camera images.
Tap **Erkennung stoppen** to return to local preview. **Schwarzmodus** makes the app surface black and
hides controls immediately without stopping the camera or a running recognition loop. Tap the black
screen to reveal controls, then **Vorschau anzeigen** to restore the preview. Controls in black mode
hide again after eight seconds. The app prevents automatic screen locking while this screen is active.
iOS system indicators remain controlled by iOS; this is not a system screen lock.

On backgrounding, the app pauses capture and releases the camera; returning to the foreground
reinitializes it and resumes recognition if it was running. Camera initialization/disposal is serialized
to handle permission dialogs and rapid lifecycle changes. No background camera operation is promised.
The camera supplies a continuous video-frame stream. Recognition admits a current frame at the
configured processing interval; while processing is busy, newer frames are skipped, not queued.
The native serial worker letterboxes BGRA for YOLO, crops the original frame for PaddleOCR Latin, and returns
strings to local confirmation (three observations within four seconds, confidence at least 0.8).
Start with a 1-second processing interval. Recognition uses no photo calls, image files or image uploads. Optional HA live view is independent.
Android local inference is not implemented. Pending HA events are held in memory, up to 100;
on overflow the oldest event is discarded and the count appears in recognition status.

Existing encrypted pairings remain valid. Legacy server settings are ignored. Continued confirmed
sightings refresh HA presence; pending events are coalesced per plate and expire after ten seconds.
Network delivery does not block frame inference.

The QR contains a temporary 256-bit key and a public offer ID. The key is never sent over the network;
AES-256-GCM and HKDF-SHA256 protect pairing, configuration and plate events, also over local HTTP.
The offer is consumed after successful exchange and expires after ten minutes. Secrets are stored in
iOS Keychain. No frame-recognition server is used by the app.
Upgrade both components and pair again when upgrading to v0.5.0 to enable encrypted-only transport.

## App navigation

With saved pairing, the app opens the camera directly. Before pairing or after explicitly
closing the camera, the dashboard shows camera readiness and authenticated HA connection status. There is one
**Camera open** action and one **Settings** entry in the top bar. Pairing is available only
under Settings → Connection; the QR imports all credentials. Manual webhook/key/device-ID
editing has been removed. Existing stored pairings remain usable.

Settings groups connection, recognition information and operation/privacy. The processing interval
and plate list are managed in HA, not a competing local editor. **Setup & help** is available
once at the bottom of Settings. Only the non-secret HA base URL is displayed.

The live camera owns start/stop and black mode; raw OCR is tucked into a Diagnose section.
The last confirmed plate and camera-relative direction remain visible. The app must stay
foregrounded. New navigation widget tests cover a 390-pixel layout, 320-pixel layout at 170%
text scaling, secret redaction and unique entry points. For optional rendered UI captures:

```bash
OPENPLATE_UI_SCREENSHOTS=/tmp/openplate-ui-preview flutter test test/app_navigation_test.dart
```

The screenshot helper loads system text fonts only on macOS; these are generated QA artifacts,
not portable pixel-perfect golden assertions.

## Motion estimates (development worktree)

The iPhone retains normalized detection boxes locally. A bounded per-plate history estimates centre
velocity (`dx`, `dy`, image widths/heights per second) and relative linear scale rate (`scale_rate`,
per second), then labels approaching/receding/stationary/unknown. This is optical expansion, not
metric 3D velocity. At least four frames spanning two seconds are needed. Clipped boxes, large
association jumps, gaps, duplicate plate identities, pose changes and lifecycle/resolution changes
invalidate the estimate. A fixed mount and unchanged zoom are prerequisites; zoom/camera/plate pose
can still mimic depth motion. Test empirically; do not authorize a door from this signal alone.

Only the small motion metadata is sent, encrypted, if HA advertises `motion_v1`. With an older HA
integration, the new app keeps sending the old observation shape. Upgrade HA before field testing.
## OCR with umlauts

The iPhone now uses the official [PaddleOCR Latin ONNX model](https://huggingface.co/PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx),
revision `89d3a50e2c27e2e7cceeab0e944c25c807d5db4f`, instead of the ASCII-only CCT reader.
The Vision post-correction path has been removed. Ä/Ö/Ü are model output classes, not substitutions
from the registered plate list. YOLO detection remains unchanged. The Python reference pipeline
still uses CCT; that is a separate backend.

Observed native contract: float32 BGR/CHW `[1,3,48,320]`, aspect-preserving bilinear resize,
normalization to [-1,1], right-zero padding. Output `fetch_name_0` is `[1,40,838]` for width 320.
The 836-entry upstream dictionary plus leading CTC blank and appended space are kept in exact order,
including duplicate glyphs. CTC repeat/blank handling replaces the old independent-slot decoder.
Unsupported characters are rejected, not silently discarded. Output is normalized to German plate
characters and confirmed across multiple frames as before.

The 8,042,023-byte model is SHA-256 pinned, downloaded once and cached next to the detector.
First use of this app version needs internet for the new OCR artifact; steady-state inference
remains offline. No old credentials, HA protocol or frame privacy settings need to change.
[Model provenance and Apache-2.0 notice](../../third_party/NOTICE.md).

Alphabet support does not guarantee accuracy: general OCR can confuse seals, EU country marks,
small dots, perspective and repeated characters. Use real mounted-camera samples before relying
on automations. Physical iPhone 12 mini accuracy, sustained speed and thermal behavior are not measured.

## Guided vehicle verification

HA advertises `vehicle_v1` and supplies registered plates through the encrypted
configuration endpoint. Vehicle detection, type/color and ReID run locally.
Initial references require explicit review in the live camera. Only confirmed
descriptors are retained in iOS Keychain; preview images stay in memory.

Settings → Vehicle profiles permits explicit opt-in to automatic comparison after
six references, three time-separated capture groups and front/rear views. This is
a minimum workflow rule, not measured security calibration. Existing presence-only
HA automations need an additional vehicle-verdict condition; they are not modified.
The three bundled models add about 18 MB. Physical iPhone performance and spoofing
tests remain open. See [the complete guide](../../docs/VEHICLE_VERIFICATION.md).

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter build ios --no-codesign
```

Native tests (replace the simulator ID with an available device):

```bash
cd ios
xcodebuild -workspace Runner.xcworkspace -scheme Runner \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' test CODE_SIGNING_ALLOWED=NO
```

Add `OPENPLATE_MODEL_TESTS=1` to explicitly opt into downloading the real models and the public,
pinned upstream smoke image. That test checks native detection/OCR against the Python reference
string `5AU5341`; it is not a German-plate accuracy or physical-iPhone performance benchmark.

## Optional encrypted Home Assistant live image

Live view is centrally controlled in HA under **OpenPlate → Configure → Camera and connection
→ Live view (WebRTC)**: enable/disable, target 12/15/24 FPS, 480p/720p. Keep the app's camera
screen open in the foreground; black mode continues capture. Recognition remains independent.
The new app uses a single native WebRTC capture source for preview, H.264 streaming and local
inference. No per-frame PNG files or second camera session are used.

Upgrade both components. The existing pairing and camera ID remain; the integration upgrades
the camera from JPEG to WebRTC after the new app connects. Use HA's live camera view rather
than the five-second JPEG thumbnail. The device must be reachable directly from the viewer;
OpenPlate supplies no TURN relay. [Full setup and limits](../../docs/REALTIME_VIDEO.md).

## Automatic startup and iOS lifecycle

Once pairing is saved, launching the app opens the camera without tapping the dashboard.
Local recognition starts as soon as the camera and models are ready. Initial model download
failures are retried after 30 seconds while the camera screen remains in the foreground.
The first camera/model startup does not wait for HA to be reachable; cached pairing and settings
are sufficient. Live video follows the central HA enable/disable setting. Preview thumbnails
wait for a successful configuration refresh so a stale saved live setting cannot start an upload.

Backgrounding or locking an iPhone pauses camera capture. Returning to the app recreates the
camera and resumes the requested recognition/live state automatically, including when the
first model load was interrupted. Explicitly stopping recognition stays stopped for that camera
screen; explicitly closing the camera returns to the dashboard without an immediate reopen loop.
A fresh app launch starts automatically again. Before pairing the setup dashboard remains visible.

For a mounted iPhone use black mode and, if desired, iOS Guided Access. Wakelock prevents automatic
screen locking while the camera is foregrounded. Black mode is an app surface, not the lock screen.
No VoIP/audio background mode or unsupported camera entitlement is declared to simulate continuous
background surveillance. Apple documents background camera interruption and separate multitasking
exceptions: https://developer.apple.com/documentation/avfoundation/avcapturesession/interruptionreason/videodevicenotavailableinbackground
