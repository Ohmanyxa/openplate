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

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter build ios --no-codesign
```
