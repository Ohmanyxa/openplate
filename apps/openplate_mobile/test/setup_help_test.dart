import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/settings.dart';
import 'package:openplate_mobile/setup_help.dart';

OpenPlateSettings settings(String webhook) => OpenPlateSettings(
  recognitionUrl: '',
  homeAssistantWebhookUrl: webhook,
  deviceId: 'iphone',
  captureIntervalSeconds: 1,
  apiKey: '',
  webhookSecret: 'x' * 32,
);

void main() {
  test(
    'display address preserves base path and port without webhook credentials',
    () {
      final address = settings(
        'https://ha.example.test:8123/home/api/webhook/private-token?key=private#private',
      ).homeAssistantBaseUrl;
      expect(address, 'https://ha.example.test:8123/home');
      expect(
        settings(
          'https://[fd00::1]:8123/api/webhook/token',
        ).homeAssistantBaseUrl,
        'https://[fd00::1]:8123',
      );
      expect(settings('').homeAssistantBaseUrl, isNull);
      expect(
        settings(
          'http://homeassistant.local:8123/api/webhook/private-token',
        ).homeAssistantBaseUrl,
        'http://homeassistant.local:8123',
      );
      expect(
        settings(
          'https://user:password@ha.local/api/webhook/token',
        ).homeAssistantBaseUrl,
        isNull,
      );
    },
  );

  testWidgets(
    'help explains unknown address instead of inventing an iPhone URL',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SetupHelpScreen()));
      expect(find.textContaining('Vor der ersten Kopplung'), findsOneWidget);
      expect(find.text('http://homeassistant.local:8123'), findsOneWidget);
      expect(find.text('Adresse kopieren'), findsNothing);
    },
  );

  testWidgets('known Home Assistant base address is selectable and copyable', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SetupHelpScreen(homeAssistantUrl: 'https://ha.example.test:8123'),
      ),
    );
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('https://ha.example.test:8123'), findsOneWidget);
    expect(find.text('Adresse kopieren'), findsOneWidget);
  });
}
