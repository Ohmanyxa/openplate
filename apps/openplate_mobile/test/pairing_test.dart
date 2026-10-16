import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openplate_mobile/pairing.dart';
import 'package:openplate_mobile/encryption.dart';

void main() {
  const key = '12345678901234567890123456789012';
  const offerId = 'offer012345678901';
  final now = DateTime.now().toUtc();

  Uri pairingUri({
    String pairingUrl =
        'http://homeassistant.local:8123/api/webhook/openplate_pairing',
    String? expiresAt,
  }) => Uri(
    scheme: 'openplate',
    host: 'pair',
    queryParameters: {
      'version': '2',
      'pairing_url': pairingUrl,
      'offer_id': offerId,
      'key': key,
      'expires_at': expiresAt ?? '${now.millisecondsSinceEpoch ~/ 1000 + 600}',
    },
  );

  test('parses a valid one-time pairing URI', () {
    final pairing = OpenPlatePairingRequest.parse(
      pairingUri().toString(),
      now: now,
    );

    expect(
      pairing.pairingUrl.toString(),
      'http://homeassistant.local:8123/api/webhook/openplate_pairing',
    );
    expect(pairing.key, key);
  });

  test('exchanges token for complete HTTPS configuration', () async {
    final pairing = OpenPlatePairingRequest.parse(
      pairingUri().toString(),
      now: now,
    );
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.followRedirects, isFalse);
      final wire = jsonDecode(request.body) as Map<String, dynamic>;
      expect(wire['offer_id'], offerId);
      expect(request.body.contains(key), isFalse);
      expect(
        await EncryptedTransport.unseal(
          wire['envelope'],
          key,
          'pairing/request/$offerId',
        ),
        {'action': 'pair', 'offer_id': offerId},
      );
      return http.Response(
        jsonEncode(
          await EncryptedTransport.seal(
            {
              'schema_version': 1,
              'device_id': 'iphone_gate',
              'recognition_url': 'https://recognition.example.test',
              'recognition_api_key': 'server-key',
              'home_assistant_webhook_url':
                  'https://ha.example.test/api/webhook/device-id',
              'webhook_secret': 'x' * 32,
              'capture_interval_seconds': 2,
            },
            key,
            'pairing/response/$offerId/${wire['envelope']['id']}/200',
          ),
        ),
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

  test('never accepts an unencrypted pairing response', () async {
    final pairing = OpenPlatePairingRequest.parse(pairingUri().toString());
    final client = MockClient(
      (request) async => http.Response(
        '{"schema_version":1,"webhook_secret":"plaintext"}',
        200,
      ),
    );
    await expectLater(pairing.exchange(client: client), throwsFormatException);
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

  test('rejects public HTTP pairing endpoints', () {
    expect(
      () => OpenPlatePairingRequest.parse(
        pairingUri(
          pairingUrl: 'http://example.com/api/webhook/openplate_pairing',
        ).toString(),
        now: now,
      ),
      throwsFormatException,
    );
  });
}
