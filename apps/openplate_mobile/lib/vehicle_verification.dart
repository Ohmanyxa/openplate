import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'settings.dart';

const vehicleModelVersion = 'vehicle-reid-0001-v1';
const vehicleThreshold =
    .88; // Conservative starting value, not a calibrated security rate.
const vehicleTypes = ['car', 'bus', 'truck', 'van'];
const vehicleColors = [
  'white',
  'gray',
  'yellow',
  'red',
  'green',
  'blue',
  'black',
];

class VehicleEvidence {
  VehicleEvidence({
    required this.type,
    required this.color,
    required this.typeConfidence,
    required this.colorConfidence,
    required this.embedding,
    required this.preview,
    required this.capturedAt,
  });
  final String type, color;
  final double typeConfidence, colorConfidence;
  final List<double> embedding;
  final Uint8List preview;
  final DateTime capturedAt;
  bool get usable =>
      vehicleTypes.contains(type) &&
      vehicleColors.contains(color) &&
      typeConfidence.isFinite &&
      typeConfidence >= .7 &&
      typeConfidence <= 1 &&
      colorConfidence.isFinite &&
      colorConfidence >= .6 &&
      colorConfidence <= 1 &&
      embedding.length == 512 &&
      embedding.every((v) => v.isFinite) &&
      (embedding.fold<double>(0, (sum, v) => sum + v * v) - 1).abs() < .05;

  factory VehicleEvidence.fromJson(Map value) => VehicleEvidence(
    type: value['type'] as String,
    color: value['color'] as String,
    typeConfidence: (value['type_confidence'] as num).toDouble(),
    colorConfidence: (value['color_confidence'] as num).toDouble(),
    embedding: (value['embedding'] as List)
        .map((v) => (v as num).toDouble())
        .toList(),
    preview: value['preview'] as Uint8List,
    capturedAt: DateTime.now().toUtc(),
  );
}

class VehicleAssessment {
  const VehicleAssessment(
    this.status, {
    this.type,
    this.color,
    this.similarity,
    this.mode = 'guided',
    this.referenceCount = 0,
  });
  final String status, mode;
  final String? type, color;
  final double? similarity;
  final int referenceCount;
  Map<String, dynamic> toJson() => {
    'status': status,
    'mode': mode,
    'type': type,
    'color': color,
    'similarity': similarity,
    'reference_count': referenceCount,
  };
}

class VehicleReference {
  VehicleReference(this.embedding, this.at, this.view);
  final List<double> embedding;
  final DateTime at;
  final String view;
  Map<String, dynamic> toJson() => {
    'embedding': embedding,
    'at': at.toIso8601String(),
    'view': view,
  };
}

class VehicleProfile {
  VehicleProfile({
    required this.type,
    required this.color,
    this.automatic = false,
    List<VehicleReference>? references,
  }) : references = references ?? [];
  final String type, color;
  bool automatic;
  final List<VehicleReference> references;
  int get encounters {
    final dates = references.map((r) => r.at).toList()..sort();
    var count = 0;
    DateTime? previous;
    for (final at in dates) {
      if (previous == null ||
          at.difference(previous) >= const Duration(seconds: 30)) {
        count++;
        previous = at;
      }
    }
    return count;
  }

  bool get ready =>
      references.length >= 6 &&
      encounters >= 3 &&
      references.any((r) => r.view == 'front') &&
      references.any((r) => r.view == 'rear');
  Map<String, dynamic> toJson() => {
    'model': vehicleModelVersion,
    'type': type,
    'color': color,
    'automatic': automatic,
    'references': references.map((r) => r.toJson()).toList(),
  };
}

typedef ReadVehicleData = Future<String?> Function(String key);
typedef WriteVehicleData = Future<void> Function(String key, String value);

class VehicleVerifier {
  VehicleVerifier(
    OpenPlateSettings settings, {
    ReadVehicleData? read,
    WriteVehicleData? write,
  }) : scope = sha256
           .convert(
             utf8.encode(
               '${settings.homeAssistantWebhookUrl}|${settings.deviceId}|${settings.webhookSecret}',
             ),
           )
           .toString(),
       _read = read ?? ((key) => const FlutterSecureStorage().read(key: key)),
       _write =
           write ??
           ((key, value) =>
               const FlutterSecureStorage().write(key: key, value: value));
  final String scope;
  final ReadVehicleData _read;
  final WriteVehicleData _write;
  final Map<String, VehicleProfile> profiles = {};
  final Map<String, int> _matches = {};
  final Map<String, DateTime> _lastAssessed = {};
  final Map<String, ({VehicleEvidence evidence, DateTime at})> _approvals = {};
  String _key(String plate) => 'openplate_vehicle_${scope}_$plate';

  Future<void> load(Iterable<String> plates) async {
    final active = plates.toSet();
    try {
      final previous =
          jsonDecode(await _read('openplate_vehicle_${scope}_index') ?? '[]')
              as List;
      for (final plate in previous.whereType<String>()) {
        if (!active.contains(plate) &&
            RegExp(r'^[A-ZÄÖÜ0-9]{1,10}$').hasMatch(plate)) {
          await _write(_key(plate), '{}');
        }
      }
    } on Object {
      /* An invalid index must not be interpreted as a profile. */
    }
    await _write(
      'openplate_vehicle_${scope}_index',
      jsonEncode(active.toList()),
    );
    profiles.removeWhere((plate, _) => !plates.contains(plate));
    for (final plate in plates) {
      if (profiles.containsKey(plate)) continue;
      try {
        final raw = await _read(_key(plate));
        if (raw == null) continue;
        final data = jsonDecode(raw) as Map;
        if (data['model'] != vehicleModelVersion ||
            !vehicleTypes.contains(data['type']) ||
            !vehicleColors.contains(data['color'])) {
          continue;
        }
        final refs = (data['references'] as List)
            .map(
              (r) => VehicleReference(
                (r['embedding'] as List)
                    .map((v) => (v as num).toDouble())
                    .toList(),
                DateTime.parse(r['at'] as String),
                r['view'] as String,
              ),
            )
            .toList();
        if (refs.length > 12 ||
            refs.any(
              (r) =>
                  r.embedding.length != 512 ||
                  !r.embedding.every((v) => v.isFinite) ||
                  (r.embedding.fold<double>(0, (sum, v) => sum + v * v) - 1)
                          .abs() >
                      .05 ||
                  !['front', 'rear'].contains(r.view),
            )) {
          continue;
        }
        final profile = VehicleProfile(
          type: data['type'] as String,
          color: data['color'] as String,
          references: refs,
        );
        profile.automatic = data['automatic'] == true && profile.ready;
        profiles[plate] = profile;
      } on Object {
        /* Corrupt or unavailable local data must never enable comparison. */
      }
    }
  }

  void resetTransient() {
    _matches.clear();
    _lastAssessed.clear();
    _approvals.clear();
  }

  VehicleAssessment assess(
    String plate,
    VehicleEvidence? evidence,
    DateTime now,
  ) {
    final profile = profiles[plate];
    final mode = profile?.automatic == true ? 'comparison' : 'guided';
    VehicleAssessment result(String status, [double? score]) =>
        VehicleAssessment(
          status,
          type: evidence?.type,
          color: evidence?.color,
          similarity: score,
          mode: mode,
          referenceCount: profile?.references.length ?? 0,
        );
    if (evidence == null ||
        !evidence.usable ||
        now.difference(evidence.capturedAt).abs() >
            const Duration(seconds: 3)) {
      _matches.remove(plate);
      _lastAssessed.remove(plate);
      return result('unknown');
    }
    if (profile == null) return result('enrollment_required');
    if (profile.type != evidence.type || profile.color != evidence.color) {
      _matches.remove(plate);
      return result('mismatch');
    }
    if (!profile.automatic) {
      final approval = _approvals[plate];
      if (approval != null &&
          now.difference(approval.at).abs() < const Duration(seconds: 30) &&
          cosine(evidence.embedding, approval.evidence.embedding) >=
              vehicleThreshold) {
        return result('confirmed');
      }
      return result('enrollment_required');
    }
    final score = profile.references
        .map((r) => cosine(evidence.embedding, r.embedding))
        .reduce(math.max);
    final previous = _lastAssessed[plate];
    if (previous == evidence.capturedAt) return result('unknown', score);
    if (previous == null ||
        evidence.capturedAt.difference(previous) > const Duration(seconds: 3)) {
      _matches.remove(plate);
    }
    _lastAssessed[plate] = evidence.capturedAt;
    _matches[plate] = score >= vehicleThreshold
        ? (_matches[plate] ?? 0) + 1
        : 0;
    return result(
      score < vehicleThreshold
          ? 'mismatch'
          : _matches[plate]! >= 3
          ? 'match'
          : 'unknown',
      score,
    );
  }

  Future<void> confirm(
    String plate,
    VehicleEvidence evidence,
    String view,
    DateTime now,
  ) async {
    if (!evidence.usable ||
        now.difference(evidence.capturedAt).abs() >
            const Duration(seconds: 15) ||
        !['front', 'rear'].contains(view)) {
      throw StateError('Aufnahme veraltet oder ungeeignet. Erneut aufnehmen.');
    }
    final existing = profiles[plate];
    if (existing?.automatic == true) {
      throw StateError('Automatisches Profil nicht selbstlernend verändern.');
    }
    if (existing != null &&
        (existing.type != evidence.type || existing.color != evidence.color)) {
      throw StateError(
        'Typ/Farbe weichen ab. Profil bewusst zurücksetzen, nicht überschreiben.',
      );
    }
    final profile = VehicleProfile(
      type: evidence.type,
      color: evidence.color,
      references: [...?existing?.references],
    );
    if (profile.references.length >= 12) {
      throw StateError('Referenzlimit erreicht. Profil prüfen.');
    }
    if (profile.references.isNotEmpty &&
        now.difference(profile.references.last.at) <
            const Duration(seconds: 3)) {
      throw StateError(
        'Zwischen Referenzen mindestens drei Sekunden Abstand lassen.',
      );
    }
    profile.references.add(
      VehicleReference(List.of(evidence.embedding), now, view),
    );
    await _write(_key(plate), jsonEncode(profile.toJson()));
    profiles[plate] = profile;
    _approvals[plate] = (evidence: evidence, at: now);
  }

  Future<void> enableComparison(String plate) async {
    final profile = profiles[plate];
    if (profile == null || !profile.ready) {
      throw StateError(
        'Mindestens sechs Referenzen, drei Begegnungen und Front/Heck erforderlich.',
      );
    }
    final data = {...profile.toJson(), 'automatic': true};
    await _write(_key(plate), jsonEncode(data));
    profile.automatic = true;
    _matches.remove(plate);
    _approvals.remove(plate);
  }

  Future<void> reset(String plate) async {
    await _write(_key(plate), '{}');
    profiles.remove(plate);
    _matches.remove(plate);
    _approvals.remove(plate);
  }

  static double cosine(List<double> a, List<double> b) {
    var dot = 0.0, aa = 0.0, bb = 0.0;
    if (a.length != 512 || b.length != 512) return -1;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      aa += a[i] * a[i];
      bb += b[i] * b[i];
    }
    return dot.isFinite && aa.isFinite && bb.isFinite && aa > 0 && bb > 0
        ? (dot / math.sqrt(aa * bb)).clamp(-1, 1)
        : -1;
  }
}
