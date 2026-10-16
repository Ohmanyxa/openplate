# OpenPlate Mobile

Flutter/iOS foreground camera client for a mounted OpenPlate camera.

## Pair with Home Assistant

1. Add OpenPlate in Home Assistant, or select **Configure → Pair an iPhone** for an existing entry.
2. Home Assistant shows the QR directly if its HTTPS address is known; otherwise enter only that address.
3. In this app, tap **iPhone per QR-Code koppeln** (or open connection management to pair again).
4. Scan the code before it expires, then confirm the QR screen in Home Assistant.
5. Configure plates and the running recognition server in Home Assistant, separately from pairing.
6. The open app retrieves recognition settings automatically within about 15 seconds. Start monitoring
   once it is ready. No manual configuration or second QR scan is needed on the iPhone.

The QR contains only a random one-time token and HTTPS exchange endpoint. The app retrieves all
settings through TLS; Home Assistant invalidates the token on first use or after ten minutes.
Secrets are stored in the iOS Keychain. Both server certificates must be trusted by iOS.

The question-mark button on the home screen opens setup help explaining which address belongs to
Home Assistant and how to find it. Before the first scan, the app does not know that address.
After pairing, the help screen displays a selectable, copyable Home Assistant base URL, excluding
the private webhook ID and query parameters. Help is also available from connection settings.

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter build ios --no-codesign
```
