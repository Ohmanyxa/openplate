# OpenPlate Mobile

Flutter/iOS foreground camera client for a mounted OpenPlate camera.

## Pair with Home Assistant

1. In Home Assistant, open **Settings → Devices & services → OpenPlate → Configure**.
2. Select **Pair an iPhone**, enter both HTTPS URLs, the recognition API key and capture interval.
3. In this app, tap **iPhone per QR-Code koppeln** (or open connection management to pair again).
4. Scan the code before it expires, then confirm the QR screen in Home Assistant.
5. Start monitoring. No manual configuration is needed on the iPhone.

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
