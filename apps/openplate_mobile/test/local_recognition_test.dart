import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    as platform;
import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/local_recognition.dart';
import 'package:openplate_mobile/video_frame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'raw video frames use only the local native channel and own buffers',
    () async {
      final bytes = Uint8List.fromList([0, 0, 255, 255, 99, 99, 99, 99]);
      final frame = VideoFrame(
        CameraImage.fromPlatformInterface(
          platform.CameraImageData(
            format: const platform.CameraImageFormat(
              ImageFormatGroup.bgra8888,
              raw: 0,
            ),
            planes: [platform.CameraImagePlane(bytes: bytes, bytesPerRow: 8)],
            width: 1,
            height: 1,
          ),
        ),
      );
      bytes.fillRange(0, bytes.length, 0);
      final methods = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(LocalPlateRecognizer.channel, (
        call,
      ) async {
        methods.add(call.method);
        if (call.method == 'initialize') return 'local CPU';
        final args = call.arguments as Map;
        expect(args['bytesPerRow'], 8);
        expect(args['bytes'], [0, 0, 255, 255, 99, 99, 99, 99]);
        return [
          {'plate': 'BTEST1', 'confidence': .95},
        ];
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          LocalPlateRecognizer.channel,
          null,
        ),
      );
      final local = LocalPlateRecognizer();
      expect(await local.initialize(), 'local CPU');
      expect((await local.recognize(frame)).single.plate, 'BTEST1');
      expect(methods, ['initialize', 'recognize']);
    },
  );

  test(
    'three distinct frames confirm a normalized plate, duplicates within a frame do not',
    () {
      final confirmation = LocalTemporalConfirmation();
      const readings = [
        PlateObservation('B-TEST 1', .95),
        PlateObservation('BTEST1', .90),
      ];
      expect(confirmation.update(readings, Duration.zero), isEmpty);
      expect(
        confirmation.update(readings, const Duration(seconds: 1)),
        isEmpty,
      );
      final result = confirmation
          .update(readings, const Duration(seconds: 2))
          .single;
      expect(result.plate, 'BTEST1');
      expect(result.observations, 3);
      expect(result.confidence, closeTo(.95, .0001));
      // Continued sightings refresh HA presence, not just the first appearance.
      expect(
        confirmation.update(readings, const Duration(seconds: 3)),
        hasLength(1),
      );
    },
  );

  test(
    'low confidence, conflicts, old observations and lifecycle resets cannot confirm',
    () {
      final confirmation = LocalTemporalConfirmation();
      const a = [PlateObservation('BTEST1', .95)];
      const b = [PlateObservation('BTEST2', .95)];
      expect(confirmation.update(a, Duration.zero), isEmpty);
      expect(confirmation.update(b, const Duration(seconds: 1)), isEmpty);
      expect(
        confirmation.update([
          const PlateObservation('BTEST1', .2),
        ], const Duration(seconds: 2)),
        isEmpty,
      );
      expect(confirmation.update(a, const Duration(seconds: 8)), isEmpty);
      expect(confirmation.update(a, const Duration(seconds: 9)), isEmpty);
      confirmation.reset();
      expect(confirmation.update(a, const Duration(seconds: 10)), isEmpty);
      expect(
        confirmation.update([
          const PlateObservation('BTEST1', double.nan),
        ], const Duration(seconds: 11)),
        isEmpty,
      );
    },
  );
}
