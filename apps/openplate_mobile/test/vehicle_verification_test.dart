import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/settings.dart';
import 'package:openplate_mobile/vehicle_verification.dart';

const settings = OpenPlateSettings(
  recognitionUrl: '',
  homeAssistantWebhookUrl: 'http://ha.local/api/webhook/test',
  deviceId: 'phone',
  captureIntervalSeconds: 1,
  apiKey: '',
  webhookSecret: 's012345678901234567890123456789012',
);

VehicleEvidence evidence(
  DateTime at, {
  int identity = 0,
  String color = 'white',
}) => VehicleEvidence(
  type: 'car',
  color: color,
  typeConfidence: .95,
  colorConfidence: .95,
  embedding: List.generate(512, (i) => i == identity ? 1.0 : 0.0),
  preview: Uint8List(0),
  capturedAt: at,
);

void main() {
  final start = DateTime.utc(2026, 10, 20);
  late Map<String, String> storage;
  late VehicleVerifier verifier;
  setUp(() {
    storage = {};
    verifier = VehicleVerifier(
      settings,
      read: (key) async => storage[key],
      write: (key, value) async {
        storage[key] = value;
      },
    );
  });
  Future<void> enroll() async {
    for (final seconds in [0, 3, 35, 38, 70, 73]) {
      final now = start.add(Duration(seconds: seconds));
      await verifier.confirm(
        'MÜAB12',
        evidence(now),
        seconds.isEven ? 'front' : 'rear',
        now,
      );
    }
  }

  test(
    'no implicit training; guided confirmation persists only descriptors',
    () async {
      expect(
        verifier.assess('MÜAB12', evidence(start), start).status,
        'enrollment_required',
      );
      expect(storage, isEmpty);
      await verifier.confirm('MÜAB12', evidence(start), 'front', start);
      expect(
        verifier.assess('MÜAB12', evidence(start), start).status,
        'confirmed',
      );
      expect(storage.values.single, isNot(contains('preview')));
      final later = start.add(const Duration(seconds: 31));
      expect(
        verifier.assess('MÜAB12', evidence(later), later).status,
        'enrollment_required',
      );
      verifier.resetTransient();
      expect(
        verifier.assess('MÜAB12', evidence(start), start).status,
        'enrollment_required',
      );
    },
  );
  test(
    'comparison requires variety and explicit opt-in; never silently activates',
    () async {
      await expectLater(verifier.enableComparison('MÜAB12'), throwsStateError);
      await enroll();
      expect(verifier.profiles['MÜAB12']!.ready, isTrue);
      expect(verifier.profiles['MÜAB12']!.automatic, isFalse);
      await verifier.enableComparison('MÜAB12');
      for (var i = 0; i < 3; i++) {
        final now = start.add(Duration(seconds: 100 + i));
        expect(
          verifier.assess('MÜAB12', evidence(now), now).status,
          i == 2 ? 'match' : 'unknown',
        );
      }
      final later = start.add(const Duration(seconds: 105));
      expect(
        verifier.assess('MÜAB12', evidence(later, identity: 1), later).status,
        'mismatch',
      );
      expect(
        verifier
            .assess('MÜAB12', evidence(later, color: 'black'), later)
            .status,
        'mismatch',
      );
      expect(verifier.assess('MÜAB12', null, later).status, 'unknown');
      await expectLater(
        verifier.confirm('MÜAB12', evidence(later), 'front', later),
        throwsStateError,
      );
    },
  );
  test('same capture and long gaps do not build a matching streak', () async {
    await enroll();
    await verifier.enableComparison('MÜAB12');
    final e = evidence(start);
    for (var i = 0; i < 4; i++) {
      expect(verifier.assess('MÜAB12', e, start).status, 'unknown');
    }
    final later = start.add(const Duration(seconds: 10));
    expect(verifier.assess('MÜAB12', evidence(later), later).status, 'unknown');
  });
  test(
    'stale confirmation and changed appearance cannot poison profiles',
    () async {
      await expectLater(
        verifier.confirm(
          'MÜAB12',
          evidence(start),
          'front',
          start.add(const Duration(seconds: 16)),
        ),
        throwsStateError,
      );
      await verifier.confirm('MÜAB12', evidence(start), 'front', start);
      final later = start.add(const Duration(seconds: 5));
      await expectLater(
        verifier.confirm(
          'MÜAB12',
          evidence(later, color: 'black'),
          'rear',
          later,
        ),
        throwsStateError,
      );
      expect(verifier.profiles['MÜAB12']!.references.length, 1);
    },
  );
  test(
    'profiles survive restart; corruption or scope change never enable them',
    () async {
      await enroll();
      await verifier.enableComparison('MÜAB12');
      final restarted = VehicleVerifier(
        settings,
        read: (key) async => storage[key],
        write: (key, value) async {
          storage[key] = value;
        },
      );
      await restarted.load(['MÜAB12']);
      expect(restarted.profiles['MÜAB12']!.automatic, isTrue);
      final unpaired = VehicleVerifier(
        const OpenPlateSettings(
          recognitionUrl: '',
          homeAssistantWebhookUrl: '',
          deviceId: 'other',
          captureIntervalSeconds: 1,
          apiKey: '',
          webhookSecret: 'different',
        ),
        read: (key) async => storage[key],
        write: (key, value) async {
          storage[key] = value;
        },
      );
      await unpaired.load(['MÜAB12']);
      expect(unpaired.profiles, isEmpty);
      await restarted.reset('MÜAB12');
      expect(restarted.profiles, isEmpty);
    },
  );
  test(
    'overflow in malformed descriptors must not become a positive match',
    () {
      expect(
        VehicleVerifier.cosine(List.filled(512, 1e308), List.filled(512, 1.0)),
        -1,
      );
    },
  );
  test('wire verdicts never include a picture or descriptor', () {
    final result = verifier.assess('MÜAB12', evidence(start), start).toJson();
    expect(result.keys.toSet(), {
      'status',
      'mode',
      'type',
      'color',
      'similarity',
      'reference_count',
    });
  });
}
