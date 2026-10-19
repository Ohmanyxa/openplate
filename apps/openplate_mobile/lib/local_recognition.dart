import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import 'openplate_api.dart';
import 'video_frame.dart';
import 'plate_identity.dart';
import 'plate_motion.dart';

class PlateObservation {
  const PlateObservation(this.plate, this.confidence, {this.box});
  final String plate;
  final double confidence;
  final PlateBox? box;
}

/// Device-local boundary. There is deliberately no HTTP/image-upload fallback.
class LocalPlateRecognizer {
  static const channel = MethodChannel('openplate/local_recognition');

  Future<String> initialize() async =>
      await channel.invokeMethod<String>('initialize') ?? 'Lokale Erkennung';

  Future<List<PlateObservation>> recognize(VideoFrame frame) async {
    if (frame.format != ImageFormatGroup.bgra8888 || frame.planes.length != 1) {
      throw UnsupportedError('Lokale Erkennung benötigt iOS-BGRA-Video-Frames');
    }
    final result = await channel.invokeListMethod<dynamic>('recognize', {
      'bytes': frame.planes.single,
      'width': frame.width,
      'height': frame.height,
      'bytesPerRow': frame.strides.single,
    });
    return (result ?? [])
        .map((value) {
          final reading = value as Map;
          final box = reading['box'] as List?;
          return PlateObservation(
            reading['plate'] as String,
            (reading['confidence'] as num).toDouble(),
            box: box != null && box.length == 4
                ? PlateBox(
                    (box[0] as num).toDouble(),
                    (box[1] as num).toDouble(),
                    (box[2] as num).toDouble(),
                    (box[3] as num).toDouble(),
                  )
                : null,
          );
        })
        .toList(growable: false);
  }
}

/// Confirm distinct processed video frames locally before emitting any plate.
class LocalTemporalConfirmation {
  LocalTemporalConfirmation({
    this.requiredObservations = 3,
    this.window = const Duration(seconds: 4),
    this.minimumConfidence = 0.8,
  });

  final int requiredObservations;
  final Duration window;
  final double minimumConfidence;
  final Map<String, List<({Duration at, double confidence})>> _candidates = {};

  void reset() => _candidates.clear();

  List<ConfirmedPlate> update(List<PlateObservation> readings, Duration now) {
    final cutoff = now - window;
    for (final observations in _candidates.values) {
      observations.removeWhere((item) => item.at < cutoff);
    }
    _candidates.removeWhere((_, observations) => observations.isEmpty);
    final distinct = <String, double>{};
    for (final reading in readings) {
      final plate = normalizePlate(reading.plate);
      if (plate.isEmpty ||
          plate.length > 10 ||
          !reading.confidence.isFinite ||
          reading.confidence < minimumConfidence ||
          reading.confidence > 1) {
        continue;
      }
      if (reading.confidence > (distinct[plate] ?? 0)) {
        distinct[plate] = reading.confidence;
      }
    }
    final confirmed = <ConfirmedPlate>[];
    for (final entry in distinct.entries) {
      if (!_candidates.containsKey(entry.key) && _candidates.length >= 256) {
        continue;
      }
      final observations = _candidates.putIfAbsent(entry.key, () => []);
      observations.add((at: now, confidence: entry.value));
      if (observations.length < requiredObservations) continue;
      confirmed.add(
        ConfirmedPlate(
          plate: entry.key,
          confidence:
              observations.map((v) => v.confidence).reduce((a, b) => a + b) /
              observations.length,
          observations: observations.length,
          // HA owns appeared/disappeared state; repeated observations keep presence fresh.
          newEvent: observations.length == requiredObservations,
        ),
      );
    }
    return confirmed;
  }
}
