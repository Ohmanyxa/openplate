import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/camera_screen.dart';
import 'package:openplate_mobile/openplate_api.dart';
import 'package:openplate_mobile/settings.dart';
import 'package:openplate_mobile/local_recognition.dart';
import 'package:openplate_mobile/video_frame.dart';
import 'package:openplate_mobile/vehicle_verification.dart';

const camera = CameraDescription(
  name: 'test-back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const previewOnly = OpenPlateSettings(
  recognitionUrl: '',
  homeAssistantWebhookUrl: '',
  deviceId: 'test',
  captureIntervalSeconds: 1,
  apiKey: '',
  webhookSecret: '',
);
const configured = OpenPlateSettings(
  recognitionUrl: '',
  homeAssistantWebhookUrl: 'http://ha.local/api/webhook/test',
  deviceId: 'test',
  captureIntervalSeconds: 1,
  apiKey: '',
  webhookSecret: 'x012345678901234567890123456789012',
);

class TestCamera extends CameraPlatform {
  TestCamera(this.directory);
  final Directory directory;
  int created = 0;
  int disposed = 0;
  int photos = 0;
  bool failInitialization = false;
  Completer<void>? initializationGate;
  final frames = StreamController<CameraImageData>.broadcast();
  @override
  bool supportsImageStreaming() => true;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) => frames.stream;
  void emitFrame() => frames.add(
    CameraImageData(
      format: const CameraImageFormat(ImageFormatGroup.bgra8888, raw: 0),
      planes: [
        CameraImagePlane(
          bytes: Uint8List.fromList([0, 0, 255, 255]),
          bytesPerRow: 4,
          bytesPerPixel: 4,
          width: 1,
          height: 1,
        ),
      ],
      width: 1,
      height: 1,
    ),
  );
  @override
  Future<int> createCamera(
    CameraDescription description,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async => ++created;
  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    await initializationGate?.future;
    if (failInitialization) {
      throw PlatformException(
        code: 'CameraAccessDenied',
        message: 'Kamerazugriff erlauben',
      );
    }
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          1920,
          1080,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => Stream.multi((_) {});
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      Stream.value(
        const DeviceOrientationChangedEvent(DeviceOrientation.portraitUp),
      );
  @override
  Future<void> dispose(int cameraId) async {
    disposed++;
  }

  @override
  Widget buildPreview(int cameraId) =>
      const ColoredBox(key: Key('test-camera-preview'), color: Colors.blue);
  @override
  Future<XFile> takePicture(int cameraId) async {
    photos++;
    return XFile('${directory.path}/nonexistent-frame-$photos.jpg');
  }
}

class TestApi extends OpenPlateApi {
  TestApi(super.settings);
  final sent = <PendingPlateEvent>[];
  final cameraFrames = <Uint8List?>[];
  @override
  Future<void> sendCameraFrame(Uint8List? jpeg, DateTime capturedAt) async {
    cameraFrames.add(jpeg);
  }

  @override
  Future<OpenPlateSettings> refreshConfiguration() async => settings;
  @override
  Future<void> sendHomeAssistantEvent(PendingPlateEvent event) async =>
      sent.add(event);
}

class TestRecognizer extends LocalPlateRecognizer {
  bool withVehicle = false;
  @override
  Future<void> configureVehicles(Iterable<String> plates) async {}
  int recognitions = 0;
  int initializations = 0;
  bool failInitialization = false;
  Completer<void>? initializationGate;
  @override
  Future<String> initialize() async {
    initializations++;
    await initializationGate?.future;
    if (failInitialization) {
      throw PlatformException(code: 'model_download', message: 'Offline');
    }
    return 'local test backend';
  }

  @override
  Future<List<PlateObservation>> recognize(VideoFrame frame) async {
    recognitions++;
    return [
      PlateObservation(
        'BTEST1',
        .95,
        vehicle: withVehicle
            ? VehicleEvidence(
                type: 'car',
                color: 'white',
                typeConfidence: .95,
                colorConfidence: .95,
                embedding: List.generate(512, (i) => i == 0 ? 1.0 : 0.0),
                preview: base64Decode(
                  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
                ),
                capturedAt: DateTime.now().toUtc(),
              )
            : null,
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CameraPlatform previousPlatform;
  late TestCamera platform;
  late Directory directory;
  const wakeChannel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('openplate-camera-test-');
    previousPlatform = CameraPlatform.instance;
    platform = TestCamera(directory);
    CameraPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          wakeChannel,
          (_) async => const StandardMessageCodec().encodeMessage([null]),
        );
  });
  tearDown(() async {
    CameraPlatform.instance = previousPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(wakeChannel, null);
    await directory.delete();
  });

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }

  testWidgets(
    'paired camera starts recognition automatically and resumes without another model load',
    (tester) async {
      final local = TestRecognizer();
      final api = TestApi(configured);
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            cameras: const [camera],
            settings: configured,
            recognizer: local,
            apiFactory: (_) => api,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(local.initializations, 1);
      expect(find.text('Läuft automatisch'), findsOneWidget);
      platform.emitFrame();
      await tester.pumpAndSettle();
      expect(local.recognitions, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(platform.disposed, 1);
      expect(find.text('Läuft automatisch'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(platform.created, 2);
      expect(local.initializations, 1);
      expect(find.text('Läuft automatisch'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'model initialization interrupted by backgrounding starts recognition when ready',
    (tester) async {
      final gate = Completer<void>();
      final local = TestRecognizer()..initializationGate = gate;
      final api = TestApi(configured);
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            cameras: const [camera],
            settings: configured,
            recognizer: local,
            apiFactory: (_) => api,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(local.initializations, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Läuft automatisch'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(local.initializations, 1);
      expect(find.text('Läuft automatisch'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'automatic model startup retries after a transient download failure',
    (tester) async {
      final local = TestRecognizer()..failInitialization = true;
      final api = TestApi(configured);
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            cameras: const [camera],
            settings: configured,
            recognizer: local,
            apiFactory: (_) => api,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(local.initializations, 1);
      expect(find.text('Automatischer neuer Versuch'), findsOneWidget);
      local.failInitialization = false;
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(local.initializations, 2);
      expect(find.text('Läuft automatisch'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'preview opens without a server and never takes or uploads a photo',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CameraScreen(cameras: [camera], settings: previewOnly),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('test-camera-preview')), findsOneWidget);
      expect(find.text('Lokale Vorschau'), findsOneWidget);
      expect(find.text('Kopplung erforderlich'), findsOneWidget);
      expect(find.text('Erkennung starten'), findsNothing);
      expect(find.text('Erkennung stoppen'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(platform.photos, 0);
      await close(tester);
      expect(platform.disposed, 1);
    },
  );

  testWidgets(
    'legacy live image works while recognition models are still loading',
    (tester) async {
      final api = TestApi(configured);
      final modelGate = Completer<void>();
      final local = TestRecognizer()..initializationGate = modelGate;
      const channel = MethodChannel('openplate/local_recognition');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'encodeCameraFrame');
            return Uint8List.fromList([255, 216, 255, 217]);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            cameras: const [camera],
            settings: configured,
            recognizer: local,
            apiFactory: (_) => api,
          ),
        ),
      );
      await tester.pumpAndSettle();
      platform.emitFrame();
      await tester.pump();
      expect(api.cameraFrames, isEmpty);
      await tester.ensureVisible(find.text('HA-Livebild starten'));
      await tester.tap(find.text('HA-Livebild starten'));
      await tester.pump();
      platform.emitFrame();
      await tester.pumpAndSettle();
      expect(api.cameraFrames.whereType<Uint8List>(), hasLength(1));
      expect(find.text('Modelle werden geladen'), findsOneWidget);
      expect(find.text('Erkennung starten'), findsNothing);
      await tester.tap(find.text('HA-Livebild stoppen'));
      await tester.pumpAndSettle();
      expect(api.cameraFrames.last, isNull);
      final count = api.cameraFrames.length;
      platform.emitFrame();
      await tester.pumpAndSettle();
      expect(api.cameraFrames.length, count);
      modelGate.complete();
      await tester.pumpAndSettle();
      await close(tester);
    },
  );

  testWidgets('black mode hides UI and preview without disposing the camera', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CameraScreen(cameras: [camera], settings: previewOnly),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Schwarzmodus'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('all-black-screen')), findsOneWidget);
    expect(find.byKey(const Key('test-camera-preview')), findsNothing);
    expect(find.byTooltip('Zur Übersicht'), findsNothing);
    expect(platform.disposed, 0);
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(find.text('Vorschau anzeigen'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('Vorschau anzeigen'), findsNothing);
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    await tester.tap(find.text('Vorschau anzeigen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('test-camera-preview')), findsOneWidget);
    expect(platform.created, 1);
    await close(tester);
  });

  testWidgets(
    'guided vehicle review sends explicit confirmation without image data',
    (tester) async {
      const settings = OpenPlateSettings(
        recognitionUrl: '',
        homeAssistantWebhookUrl: 'http://ha.local/api/webhook/test',
        deviceId: 'test',
        captureIntervalSeconds: 1,
        apiKey: '',
        webhookSecret: 'x012345678901234567890123456789012',
        registeredPlates: {'BTEST1': 'Test car'},
        supportsVehicleVerification: true,
      );
      final stored = <String, String>{};
      final verifier = VehicleVerifier(
        settings,
        read: (key) async => stored[key],
        write: (key, value) async {
          stored[key] = value;
        },
      );
      final local = TestRecognizer()..withVehicle = true;
      final api = TestApi(settings);
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            cameras: const [camera],
            settings: settings,
            recognizer: local,
            apiFactory: (_) => api,
            vehicleVerifierFactory: (_) => verifier,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() async {
          platform.emitFrame();
          await Future<void>.delayed(const Duration(milliseconds: 1100));
        });
        await tester.pumpAndSettle();
      }
      expect(api.sent.last.plate.vehicle!.status, 'enrollment_required');
      await tester.ensureVisible(find.text('BTEST1 · Fahrzeug bestätigen'));
      await tester.tap(find.text('BTEST1 · Fahrzeug bestätigen'));
      await tester.pumpAndSettle();
      expect(find.text('Ist das dein Fahrzeug für BTEST1?'), findsOneWidget);
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(verifier.profiles['BTEST1']!.references.length, 1);
      expect(api.sent.last.plate.vehicle!.status, 'confirmed');
      expect(
        api.sent.last.plate.vehicle!.toJson().containsKey('embedding'),
        isFalse,
      );
      await close(tester);
    },
  );

  testWidgets(
    'recognition continues in black mode and pauses in the background',
    (tester) async {
      final api = TestApi(configured);
      final local = TestRecognizer();
      await tester.pumpWidget(
        MaterialApp(
          home: CameraScreen(
            cameras: const [camera],
            settings: configured,
            apiFactory: (_) => api,
            recognizer: local,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(local.recognitions, 0);
      expect(find.text('Läuft automatisch'), findsOneWidget);
      platform.emitFrame();
      await tester.pump();
      await tester.runAsync(() async {
        platform.emitFrame();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(local.recognitions, 1);
      await tester.tap(find.text('Schwarzmodus'));
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        platform.emitFrame();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(local.recognitions, greaterThan(1));
      expect(api.sent, isEmpty);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      });
      platform.emitFrame();
      await tester.pump();
      await tester.pump();
      expect(api.sent.single.plate.plate, 'BTEST1');
      expect(api.sent.single.plate.observations, 3);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      final pausedPhotos = platform.photos;
      await tester.pump(const Duration(seconds: 3));
      expect(platform.photos, pausedPhotos);
      expect(platform.photos, 0);
      expect(platform.disposed, 1);
      expect(find.text('Läuft automatisch'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(platform.created, 2);
      await close(tester);
    },
  );

  testWidgets(
    'permission failure is recoverable without leaving the camera screen',
    (tester) async {
      platform.failInitialization = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: CameraScreen(cameras: [camera], settings: previewOnly),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Kamerafehler'), findsOneWidget);
      platform.failInitialization = false;
      await tester.tap(find.text('Kamera erneut starten'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('test-camera-preview')), findsOneWidget);
      expect(platform.created, 2);
      await close(tester);
      expect(platform.disposed, 2);
    },
  );

  testWidgets(
    'suspension during initialization does not leave two cameras open',
    (tester) async {
      final gate = Completer<void>();
      platform.initializationGate = gate;
      await tester.pumpWidget(
        const MaterialApp(
          home: CameraScreen(cameras: [camera], settings: previewOnly),
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      gate.complete();
      await tester.pumpAndSettle();
      expect(platform.created, 2);
      expect(platform.disposed, 1);
      expect(find.byKey(const Key('test-camera-preview')), findsOneWidget);
      await close(tester);
      expect(platform.disposed, 2);
    },
  );
}
