import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/openplate_api.dart';
import 'package:openplate_mobile/settings.dart';

void main() {
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
