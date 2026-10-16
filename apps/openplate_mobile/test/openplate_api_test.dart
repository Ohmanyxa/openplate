import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openplate_mobile/openplate_api.dart';
import 'package:openplate_mobile/settings.dart';

void main() {
  const paired = OpenPlateSettings(
    recognitionUrl: '',
    homeAssistantWebhookUrl: 'https://ha.local/api/webhook/test',
    deviceId: 'iphone_gate',
    captureIntervalSeconds: 1,
    apiKey: '',
    webhookSecret: '12345678901234567890123456789012',
  );

  test('pairing does not require a recognition server; monitoring does', () {
    expect(paired.isPaired, isTrue);
    expect(paired.isComplete, isFalse);
  });

  test(
    'retrieves later server settings through an authenticated request',
    () async {
      final client = MockClient((request) async {
        expect(jsonDecode(request.body)['event_type'], 'device.configuration');
        final timestamp = request.headers['X-OpenPlate-Timestamp'];
        final nonce = request.headers['X-OpenPlate-Nonce'];
        expect(nonce, isNotEmpty);
        final expected = Hmac(sha256, utf8.encode(paired.webhookSecret))
            .convert(utf8.encode('$timestamp\n$nonce\n${request.body}'))
            .toString();
        expect(request.headers['X-OpenPlate-Signature'], expected);
        return http.Response(
          jsonEncode({
            'schema_version': 1,
            'device_id': paired.deviceId,
            'home_assistant_webhook_url': paired.homeAssistantWebhookUrl,
            'webhook_secret': paired.webhookSecret,
            'recognition_url': 'https://recognition.local',
            'recognition_api_key': 'configured-in-ha',
            'capture_interval_seconds': 2,
          }),
          200,
        );
      });
      final updated = await OpenPlateApi(
        paired,
        client: client,
      ).refreshConfiguration();
      expect(updated.isComplete, isTrue);
      expect(updated.apiKey, 'configured-in-ha');
      expect(updated.captureIntervalSeconds, 2);
    },
  );

  test('recognition response is decoded', () {
    final plate = ConfirmedPlate.fromJson({
      'plate': 'BTEST1',
      'confidence': 0.95,
      'observations': 3,
      'new_event': true,
    });

    expect(plate.plate, 'BTEST1');
    expect(plate.newEvent, isTrue);
  });

  test('only complete HTTPS settings can start monitoring', () {
    const settings = OpenPlateSettings(
      recognitionUrl: 'https://openplate.local',
      homeAssistantWebhookUrl: 'https://ha.local/api/webhook/test',
      deviceId: 'iphone_gate',
      captureIntervalSeconds: 1,
      apiKey: 'api-key',
      webhookSecret: '12345678901234567890123456789012',
    );

    expect(settings.isComplete, isTrue);
  });
}
