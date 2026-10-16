# OpenPlate Mobile

Flutter/iOS foreground camera client for a mounted OpenPlate camera.

## Pair with Home Assistant

1. Add OpenPlate in Home Assistant, or select **Configure → Pair an iPhone** for an existing entry.
2. Home Assistant detects its local address and shows the QR. If needed, confirm or correct the suggested
   `http://homeassistant.local:8123` address. No HA certificates are required.
3. In this app, tap **iPhone per QR-Code koppeln** (or open connection management to pair again).
4. Scan the code before it expires, then confirm the QR screen in Home Assistant.
5. Configure plates and the running recognition server in Home Assistant, separately from pairing.
6. The open app retrieves recognition settings automatically within about 15 seconds. Start monitoring
   once it is ready. No manual configuration or second QR scan is needed on the iPhone.

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
