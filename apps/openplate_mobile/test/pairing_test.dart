import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/pairing.dart';

void main() {
  const secret = '12345678901234567890123456789012';
  final now = DateTime.fromMillisecondsSinceEpoch(
    1700000000 * 1000,
    isUtc: true,
  );

  test('parses a valid versioned pairing URI', () {
    final uri = Uri(
      scheme: 'openplate',
      host: 'pair',
      queryParameters: {
        'version': '1',
        'device_id': 'iphone_gate',
        'home_assistant_webhook_url':
            'https://ha.example.test/api/webhook/webhook-id',
        'webhook_secret': secret,
        'expires_at': '1700000600',
      },
    );

    final pairing = OpenPlatePairing.parse(uri.toString(), now: now);

    expect(pairing.deviceId, 'iphone_gate');
    expect(
      pairing.homeAssistantWebhookUrl,
      'https://ha.example.test/api/webhook/webhook-id',
    );
    expect(pairing.webhookSecret, secret);
  });

  test('rejects expired pairing codes', () {
    final uri = Uri(
      scheme: 'openplate',
      host: 'pair',
      queryParameters: {
        'version': '1',
        'device_id': 'iphone_gate',
        'home_assistant_webhook_url':
            'https://ha.example.test/api/webhook/webhook-id',
        'webhook_secret': secret,
        'expires_at': '1699999999',
      },
    );

    expect(
      () => OpenPlatePairing.parse(uri.toString(), now: now),
      throwsFormatException,
    );
  });

  test('rejects non-HTTPS webhooks', () {
    final uri = Uri(
      scheme: 'openplate',
      host: 'pair',
      queryParameters: {
        'version': '1',
        'device_id': 'iphone_gate',
        'home_assistant_webhook_url': 'http://ha.local/api/webhook/webhook-id',
        'webhook_secret': secret,
        'expires_at': '1700000600',
      },
    );

    expect(
      () => OpenPlatePairing.parse(uri.toString(), now: now),
      throwsFormatException,
    );
  });
}
