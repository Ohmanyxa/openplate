import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openplate_mobile/openplate_api.dart';
import 'package:openplate_mobile/pairing.dart';
import 'package:openplate_mobile/settings.dart';

class RecordingClient extends http.BaseClient {
  final inner = http.Client();
  final bodies = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request && request.method == 'POST') {
      bodies.add(request.body);
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  final base = Platform.environment['OPENPLATE_INTEROP_URL'];
  test(
    'real Dart/Python pairing, configuration and plate events over HTTP',
    () async {
      final client = RecordingClient();
      addTearDown(client.close);
      final before = jsonDecode(
        (await client.get(Uri.parse('$base/test/state'))).body,
      );
      final bootstrap = jsonDecode(
        (await client.get(Uri.parse('$base/test/bootstrap'))).body,
      );
      final pairing = OpenPlatePairingRequest.parse(bootstrap['qr'] as String);
      final configuration = await pairing.exchange(client: client);
      final settings = OpenPlateSettings.fromPairing(configuration);
      expect(settings.isPaired, isTrue);
      expect(settings.homeAssistantWebhookUrl.startsWith('http://'), isTrue);
      expect(settings.isComplete, isFalse);
      final api = OpenPlateApi(settings, client: client);
      await api.refreshConfiguration();
      final event = PendingPlateEvent.fromPlate(
        const ConfirmedPlate(
          plate: 'BTEST1',
          confidence: 0.97,
          observations: 3,
          newEvent: true,
        ),
      );
      await api.sendHomeAssistantEvent(event);
      final captured = client.bodies.last;
      final replay = await client.post(
        Uri.parse(settings.homeAssistantWebhookUrl),
        headers: {'Content-Type': 'application/json'},
        body: captured,
      );
      expect(replay.statusCode, 409);
      await api.sendHomeAssistantEvent(event);
      final state = jsonDecode(
        (await client.get(Uri.parse('$base/test/state'))).body,
      );
      expect(state['recognized'], (before['recognized'] as int) + 1);
      expect(state['last_event']['plate'], 'BTEST1');
      expect(
        (state['last_event'] as Map<String, dynamic>).containsKey('session_id'),
        isFalse,
      );
      for (final body in client.bodies) {
        for (final secret in [pairing.key, settings.webhookSecret, 'BTEST1']) {
          expect(body.contains(secret), isFalse);
        }
      }
      await expectLater(
        pairing.exchange(client: client),
        throwsFormatException,
      );
    },
    skip: base == null
        ? 'Run interop_server.py and set OPENPLATE_INTEROP_URL'
        : false,
  );
}
