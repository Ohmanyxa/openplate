# OpenPlate Mobile

Flutter/iOS foreground camera client for a mounted OpenPlate camera.

## Pair with Home Assistant

1. Add OpenPlate in Home Assistant, or select **Configure → Pair an iPhone** for an existing entry.
2. Home Assistant detects its local address and shows the QR. If needed, confirm or correct the suggested
   `http://homeassistant.local:8123` address. No HA certificates are required.
3. In this app, tap **iPhone per QR-Code koppeln** (or open connection management to pair again).
4. Scan the code before it expires, then confirm the QR screen in Home Assistant.
5. Configure plates and the running recognition server in Home Assistant, separately from pairing.
6. The open app retrieves recognition settings automatically within about 15 seconds, also while the
   camera screen is open. No manual configuration or second QR scan is needed on the iPhone.

## Live preview and black mode

Tap **Kamera öffnen** to align the camera. The local live preview works even before pairing or before
configuring a recognition server. It neither takes still photos nor uploads frames by itself. HA
connection and recognition status are displayed separately; saved pairing data alone is not shown as
a verified live connection.

Once the recognition server is configured, tap **Erkennung starten** to send frames for recognition.
Tap **Erkennung stoppen** to return to local preview. **Schwarzmodus** makes the app surface black and
hides controls immediately without stopping the camera or a running recognition loop. Tap the black
screen to reveal controls, then **Vorschau anzeigen** to restore the preview. Controls in black mode
hide again after eight seconds. The app prevents automatic screen locking while this screen is active.
iOS system indicators remain controlled by iOS; this is not a system screen lock.

On backgrounding, the app pauses capture and releases the camera; returning to the foreground
reinitializes it and resumes recognition if it was running. Camera initialization/disposal is serialized
to handle permission dialogs and rapid lifecycle changes. No background camera operation is promised.
Temporary frames are removed after processing. Pending HA events are held in memory, up to 100;
on overflow the oldest event is discarded and the count appears in recognition status.

Existing v0.5.0 pairings remain valid. A message that the recognition server is missing is independent
of pairing: configure the running server under **OpenPlate → Configure → Configure recognition server**
in HA. OpenPlate does not provision that server automatically.

The QR contains a temporary 256-bit key and a public offer ID. The key is never sent over the network;
AES-256-GCM and HKDF-SHA256 protect pairing, configuration and plate events, also over local HTTP.
The offer is consumed after successful exchange and expires after ten minutes. Secrets are stored in
iOS Keychain. The separate recognition server still requires HTTPS for camera images.
Upgrade both components and pair again when upgrading to v0.5.0 to enable encrypted-only transport.

The question-mark button on the home screen opens setup help explaining which address belongs to
Home Assistant and how to find it. Before the first scan it shows the usual local address as an
unverified suggestion, not a discovered address.
After pairing, the help screen displays a selectable, copyable Home Assistant base URL, excluding
the private webhook ID and query parameters. Help is also available from connection settings.

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter build ios --no-codesign
```
