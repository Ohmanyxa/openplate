import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/app_ui.dart';
import 'package:openplate_mobile/camera_controls.dart';

void main() {
  final output = Platform.environment['OPENPLATE_UI_SCREENSHOTS'];
  setUpAll(() async {
    if (output != null && Platform.isMacOS) {
      await (FontLoader('Roboto')..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '/System/Library/Fonts/Supplemental/Arial.ttf',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  Future<void> capture(WidgetTester tester, String name) async {
    if (output == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('capture')),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  }

  Widget screen({
    double scale = 1,
    bool starting = false,
    bool black = false,
    VoidCallback? onBack,
    VoidCallback? onBlack,
  }) => RepaintBoundary(
    key: const Key('capture'),
    child: MaterialApp(
      theme: openPlateTheme(),
      debugShowCheckedModeBanner: false,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: black
                      ? [Colors.black, Colors.black]
                      : [const Color(0xFF576A75), const Color(0xFF1C2930)],
                ),
              ),
            ),
            SafeArea(
              child: CameraControls(
                paired: true,
                blackMode: black,
                statusLabel: starting ? 'Startet' : 'Aktiv',
                statusTone: starting
                    ? CameraStatusTone.pending
                    : CameraStatusTone.active,
                statuses: [
                  CameraStatusItem(
                    Icons.center_focus_strong_outlined,
                    'Erkennung',
                    starting ? 'Modelle werden geladen' : 'Läuft automatisch',
                    starting
                        ? CameraStatusTone.pending
                        : CameraStatusTone.active,
                  ),
                  const CameraStatusItem(
                    Icons.home_outlined,
                    'Home Assistant',
                    'Verbunden',
                    CameraStatusTone.active,
                  ),
                  const CameraStatusItem(
                    Icons.videocam_outlined,
                    'Livebild',
                    'Live verbunden',
                    CameraStatusTone.active,
                  ),
                ],
                lastPlate: starting ? null : 'MÜ AB123',
                motionStatus: 'Fahrzeug nähert sich',
                vehicleLabel: starting ? null : 'Passt zum Profil',
                details: const {
                  'Bildqualität': '720p · Ziel 24 FPS',
                  'Kamera': 'Kamera aktiv',
                },
                onBack: onBack ?? () {},
                onToggleBlackMode: onBlack ?? () {},
              ),
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets(
    'automatic camera has clear navigation and statuses without recognition controls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var back = 0;
      var black = 0;
      await tester.pumpWidget(
        screen(onBack: () => back++, onBlack: () => black++),
      );
      await tester.pumpAndSettle();
      expect(find.text('Erkennung starten'), findsNothing);
      expect(find.text('Erkennung stoppen'), findsNothing);
      expect(find.text('Läuft automatisch'), findsOneWidget);
      expect(find.text('MÜ AB123'), findsOneWidget);
      await tester.runAsync(() => capture(tester, 'camera-running'));
      await tester.tap(find.byTooltip('Zur Übersicht'));
      expect(back, 1);
      await tester.ensureVisible(find.text('Schwarzmodus'));
      await tester.tap(find.text('Schwarzmodus'));
      expect(black, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'startup, black mode and large text stay readable and scrollable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(screen(scale: 1.6, starting: true, black: true));
      await tester.pumpAndSettle();
      expect(find.text('Modelle werden geladen'), findsOneWidget);
      expect(find.byTooltip('Zur Übersicht'), findsOneWidget);
      await tester.runAsync(() => capture(tester, 'camera-large-text'));
      await tester.scrollUntilVisible(
        find.text('Details'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('720p'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
