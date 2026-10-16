import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openplate_mobile/openplate_api.dart';
import 'package:openplate_mobile/settings.dart';
import 'package:openplate_mobile/encryption.dart';

void main() {
  const paired = OpenPlateSettings(
    recognitionUrl: '',
    homeAssistantWebhookUrl: 'http://ha.local:8123/api/webhook/test',
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
        final envelope = jsonDecode(request.body) as Map<String, dynamic>;
        final payload = await EncryptedTransport.unseal(
          envelope,
          paired.webhookSecret,
          'device/request/test',
        );
        expect(payload['event_type'], 'device.configuration');
        expect(request.body.contains('device.configuration'), isFalse);
        expect(request.body.contains(paired.webhookSecret), isFalse);
        return http.Response(
          jsonEncode(
            await EncryptedTransport.seal(
              {
                'schema_version': 1,
                'device_id': paired.deviceId,
                'home_assistant_webhook_url': paired.homeAssistantWebhookUrl,
                'webhook_secret': paired.webhookSecret,
                'recognition_url': 'https://recognition.local',
                'recognition_api_key': 'configured-in-ha',
                'capture_interval_seconds': 2,
                'session_id': 'session012345678901',
              },
              paired.webhookSecret,
              'device/response/test/${envelope['id']}/200',
            ),
          ),
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

  test('does not trust a plaintext success response over HTTP', () async {
    final client = MockClient(
      (request) async => http.Response('{"accepted":true}', 200),
    );
    await expectLater(
      OpenPlateApi(paired, client: client).refreshConfiguration(),
      throwsFormatException,
    );
  });

  test(
    'refreshes the session and retries after a Home Assistant restart',
    () async {
      var configurationRequests = 0;
      var observations = 0;
      final client = MockClient((request) async {
        final envelope = jsonDecode(request.body) as Map<String, dynamic>;
        final payload = await EncryptedTransport.unseal(
          envelope,
          paired.webhookSecret,
          'device/request/test',
        );
        var status = 200;
        Map<String, dynamic> result;
        if (payload['event_type'] == 'device.configuration') {
          configurationRequests++;
          result = {
            'schema_version': 1,
            'device_id': paired.deviceId,
            'home_assistant_webhook_url': paired.homeAssistantWebhookUrl,
            'webhook_secret': paired.webhookSecret,
            'capture_interval_seconds': 1,
            'session_id': 'session-number-$configurationRequests',
          };
        } else {
          observations++;
          expect(request.body.contains('BTEST1'), isFalse);
          if (observations == 1) {
            status = 428;
            result = {'error': 'session required'};
          } else {
            expect(payload['session_id'], 'session-number-2');
            result = {'accepted': true};
          }
        }
        return http.Response(
          jsonEncode(
            await EncryptedTransport.seal(
              result,
              paired.webhookSecret,
              'device/response/test/${envelope['id']}/$status',
            ),
          ),
          status,
        );
      });
      await OpenPlateApi(paired, client: client).sendHomeAssistantEvent(
        PendingPlateEvent.fromPlate(
          const ConfirmedPlate(
            plate: 'BTEST1',
            confidence: 0.95,
            observations: 3,
            newEvent: true,
          ),
        ),
      );
      expect(configurationRequests, 2);
      expect(observations, 2);
    },
  );

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
