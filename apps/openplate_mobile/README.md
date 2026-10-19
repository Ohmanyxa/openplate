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

After pairing, tap **Erkennung starten**. The first start downloads about 11 MB of pinned models over
HTTPS and verifies their SHA-256 hashes. Subsequent recognition works offline on the iPhone CPU via
ONNX Runtime 1.30.0, not yet Core ML/Neural Engine. iOS 15.1+ is required.
Camera frames never leave the phone; only confirmed plate strings and metadata go encrypted to HA.
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
The native serial worker letterboxes BGRA for YOLO, crops the original frame for CCT OCR, and returns
strings to local confirmation (three observations within four seconds, confidence at least 0.8).
Start with a 1-second processing interval. There are no photo calls, image files or image uploads.
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

The question-mark button on the home screen opens setup help explaining which address belongs to
Home Assistant and how to find it. Before the first scan it shows the usual local address as an
unverified suggestion, not a discovered address.
After pairing, the help screen displays a selectable, copyable Home Assistant base URL, excluding
the private webhook ID and query parameters. Help is also available from connection settings.

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
The CCT model still cannot output umlauts. Registration preserves them rather than making unsafe
automatic aliases; this change does not add umlaut recognition to the model.

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
