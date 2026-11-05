import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/app_ui.dart';
import 'package:openplate_mobile/main.dart';
import 'package:openplate_mobile/openplate_api.dart';
import 'package:camera/camera.dart';
import 'package:openplate_mobile/settings.dart';

const paired = OpenPlateSettings(
  recognitionUrl: '',
  homeAssistantWebhookUrl:
      'http://homeassistant.local:8123/api/webhook/private-id',
  deviceId: 'iphone_entry',
  captureIntervalSeconds: 1,
  apiKey: '',
  webhookSecret: 'private-key-012345678901234567890123456789',
);

class OfflineApi extends OpenPlateApi {
  OfflineApi(super.settings);
  int refreshes = 0;
  @override
  Future<OpenPlateSettings> refreshConfiguration() async {
    refreshes++;
    throw const HttpException('HA offline');
  }
}

void main() {
  final screenshots = Platform.environment['OPENPLATE_UI_SCREENSHOTS'];
  setUpAll(() async {
    if (screenshots != null && Platform.isMacOS) {
      final font = FontLoader('Roboto')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/System/Library/Fonts/Supplemental/Arial.ttf',
              ).readAsBytes(),
            ),
          ),
        );
      await font.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  Future<void> capture(WidgetTester tester, String name) async {
    if (screenshots == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('capture')),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(screenshots).create(recursive: true);
    await File(
      '$screenshots/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  }

  testWidgets(
    'saved pairing opens camera immediately even if HA is offline; explicit close stays closed',
    (tester) async {
      final api = OfflineApi(paired);
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            cameras: const [
              CameraDescription(
                name: 'back',
                lensDirection: CameraLensDirection.back,
                sensorOrientation: 90,
              ),
            ],
            settingsLoader: () async => paired,
            apiFactory: (_) => api,
            cameraBuilder: (_) {
              opens++;
              return Scaffold(
                appBar: AppBar(
                  title: const Text('Automatisch gestartete Kamera'),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Automatisch gestartete Kamera'), findsOneWidget);
      expect(opens, 1);
      expect(api.refreshes, 0);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Automatisch gestartete Kamera'), findsNothing);
      expect(find.text('Kamera öffnen'), findsOneWidget);
      expect(opens, 1);
      expect(api.refreshes, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'without pairing the app keeps setup visible and does not start a camera',
    (tester) async {
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            cameras: const [
              CameraDescription(
                name: 'back',
                lensDirection: CameraLensDirection.back,
                sensorOrientation: 90,
              ),
            ],
            settingsLoader: () async => const OpenPlateSettings(
              recognitionUrl: '',
              homeAssistantWebhookUrl: '',
              deviceId: 'unpaired',
              captureIntervalSeconds: 1,
              apiKey: '',
              webhookSecret: '',
            ),
            cameraBuilder: (_) {
              opens++;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(opens, 0);
      expect(find.byTooltip('Einstellungen'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('dashboard has one settings entry and one camera action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var cameraOpens = 0;
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('capture'),
        child: MaterialApp(
          theme: openPlateTheme(),
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) => DashboardScreen(
              settings: paired,
              cameraAvailable: true,
              verified: true,
              onOpenCamera: () => cameraOpens++,
              onOpenSettings: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(initial: paired),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Einstellungen'), findsOneWidget);
    expect(find.text('Kamera öffnen'), findsOneWidget);
    expect(find.text('Verbunden · verschlüsselt'), findsOneWidget);
    expect(find.textContaining('QR-Code scannen'), findsNothing);
    await tester.runAsync(() => capture(tester, 'dashboard'));
    await tester.tap(find.text('Kamera öffnen'));
    expect(cameraOpens, 1);
    await tester.tap(find.byTooltip('Einstellungen'));
    await tester.pumpAndSettle();
    expect(find.text('Einstellungen'), findsOneWidget);
    expect(find.text('iPhone neu koppeln'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.textContaining('private-id'), findsNothing);
    expect(find.textContaining('private-key'), findsNothing);
    await tester.runAsync(() => capture(tester, 'settings'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text and narrow screens remain scrollable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: openPlateTheme(),
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.7)),
          child: child!,
        ),
        home: const SettingsScreen(initial: paired),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Einrichtung & Hilfe'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Einrichtung & Hilfe'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
