import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openplate_mobile/pairing.dart';

void main() {
  const token = '12345678901234567890123456789012';
  final now = DateTime.fromMillisecondsSinceEpoch(
    1700000000 * 1000,
    isUtc: true,
  );

  Uri pairingUri({
    String pairingUrl = 'https://ha.example.test/api/webhook/openplate_pairing',
    String expiresAt = '1700000600',
  }) => Uri(
    scheme: 'openplate',
    host: 'pair',
    queryParameters: {
      'version': '1',
      'pairing_url': pairingUrl,
      'token': token,
      'expires_at': expiresAt,
    },
  );

  test('parses a valid one-time pairing URI', () {
    final pairing = OpenPlatePairingRequest.parse(
      pairingUri().toString(),
      now: now,
    );

    expect(
      pairing.pairingUrl.toString(),
      'https://ha.example.test/api/webhook/openplate_pairing',
    );
    expect(pairing.token, token);
  });

  test('exchanges token for complete HTTPS configuration', () async {
    final pairing = OpenPlatePairingRequest.parse(
      pairingUri().toString(),
      now: now,
    );
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(jsonDecode(request.body), {'token': token});
      return http.Response(
        jsonEncode({
          'schema_version': 1,
          'device_id': 'iphone_gate',
          'recognition_url': 'https://recognition.example.test',
          'recognition_api_key': 'server-key',
          'home_assistant_webhook_url':
              'https://ha.example.test/api/webhook/device-id',
          'webhook_secret': 'x' * 32,
          'capture_interval_seconds': 2,
        }),
        200,
      );
    });

    final configuration = await pairing.exchange(client: client);

    expect(configuration.deviceId, 'iphone_gate');
    expect(configuration.recognitionApiKey, 'server-key');
    expect(configuration.captureIntervalSeconds, 2);
  });

  test('rejects expired pairing codes', () {
    expect(
      () => OpenPlatePairingRequest.parse(
        pairingUri(expiresAt: '1699999999').toString(),
        now: now,
      ),
      throwsFormatException,
    );
  });

  test('pairs securely before a recognition server is configured', () {
    final configuration = OpenPlatePairingConfiguration.fromJson({
      'schema_version': 1,
      'device_id': 'iphone_gate',
      'home_assistant_webhook_url':
          'https://ha.example.test/api/webhook/device-id',
      'webhook_secret': 'x' * 32,
      'capture_interval_seconds': 1,
    });
    expect(configuration.recognitionUrl, isEmpty);
    expect(configuration.recognitionApiKey, isEmpty);
  });

  test(
    'does not accept an incomplete or insecure recognition configuration',
    () {
      for (final url in [
        'http://recognition.local',
        'https://recognition.local',
      ]) {
        expect(
          () => OpenPlatePairingConfiguration.fromJson({
            'schema_version': 1,
            'device_id': 'iphone_gate',
            'recognition_url': url,
            'home_assistant_webhook_url':
                'https://ha.example.test/api/webhook/device-id',
            'webhook_secret': 'x' * 32,
            'capture_interval_seconds': 1,
          }),
          throwsFormatException,
        );
      }
    },
  );

  test('rejects non-HTTPS pairing endpoints', () {
    expect(
      () => OpenPlatePairingRequest.parse(
        pairingUri(
          pairingUrl: 'http://ha.local/api/webhook/openplate_pairing',
        ).toString(),
        now: now,
      ),
      throwsFormatException,
    );
  });
}
