# OpenPlate Mobile

Flutter/iOS foreground camera client for a mounted OpenPlate camera.

## Pair with Home Assistant

1. In Home Assistant, open **Settings → Devices & services → OpenPlate → Configure**.
2. Select **Pair an iPhone**, verify the HTTPS base URL and continue.
3. In this app, open **Connection** and select **Scan Home Assistant QR code**.
4. Scan the code before it expires, then confirm the QR screen in Home Assistant.
5. Enter the separate recognition-server HTTPS URL and API key, then save.

The QR code transfers the device ID, webhook URL and a freshly generated HMAC signing key. Secrets
are stored in the iOS Keychain. The app accepts HTTPS endpoints only.

## Development

```bash
flutter pub get
flutter analyze
flutter test
flutter build ios --no-codesign
```
