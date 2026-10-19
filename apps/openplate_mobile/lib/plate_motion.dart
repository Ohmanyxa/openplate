import 'dart:math' as math;

class PlateBox {
  const PlateBox(this.x, this.y, this.width, this.height);
  final double x, y, width, height;
  double get cx => x + width / 2;
  double get cy => y + height / 2;
  double get area => width * height;
  bool get usable =>
      [x, y, width, height].every((v) => v.isFinite) &&
      width > 0 &&
      height > 0 &&
      x > .01 &&
      y > .01 &&
      x + width < .99 &&
      y + height < .99;
}

class PlateMotion {
  const PlateMotion({
    this.direction = 'unknown',
    this.dx,
    this.dy,
    this.scaleRate,
    this.samples = 0,
    this.spanSeconds = 0,
  });
  final String direction;
  final double? dx, dy, scaleRate;
  final int samples;
  final double spanSeconds;
  Map<String, dynamic> toJson() => {
    'direction': direction,
    'dx': dx,
    'dy': dy,
    'scale_rate': scaleRate,
    'samples': samples,
    'span_seconds': spanSeconds,
  };
  String get label => switch (direction) {
    'approaching' => 'Annäherung (Schätzung)',
    'receding' => 'Entfernung (Schätzung)',
    'stationary' => 'Stationär (Schätzung)',
    _ => 'Richtung unbekannt',
  };
}

typedef _Sample = ({Duration at, PlateBox box});

/// Bounding-box optical expansion, NOT calibrated 3D velocity or authorization.
/// Fixed camera/zoom and a stable plate pose are prerequisites.
class PlateMotionTracker {
  final Map<String, List<_Sample>> _tracks = {};
  void reset() => _tracks.clear();
  void discard(String plate) => _tracks.remove(plate);

  PlateMotion update(String plate, PlateBox? box, Duration now) {
    _tracks.removeWhere(
      (_, track) => now - track.last.at > const Duration(seconds: 5),
    );
    if (box == null || !box.usable) {
      discard(plate);
      return const PlateMotion();
    }
    if (!_tracks.containsKey(plate) && _tracks.length >= 128) {
      return const PlateMotion();
    }
    final track = _tracks.putIfAbsent(plate, () => []);
    if (track.isNotEmpty) {
      final previous = track.last;
      final gap = now - previous.at;
      final jump = math.sqrt(
        math.pow(box.cx - previous.box.cx, 2) +
            math.pow(box.cy - previous.box.cy, 2),
      );
      final areaChange = box.area / previous.box.area;
      if (gap <= Duration.zero ||
          gap > const Duration(milliseconds: 2500) ||
          jump > .2 ||
          areaChange > 2 ||
          areaChange < .5) {
        track.clear();
      }
    }
    track.add((at: now, box: box));
    track.removeWhere((s) => now - s.at > const Duration(seconds: 5));
    while (track.length > 8) {
      track.removeAt(0);
    }
    final span = (now - track.first.at).inMicroseconds / 1e6;
    if (track.length < 4 || span < 2) return const PlateMotion();
    final ratios = track.map((s) => s.box.width / s.box.height).toList();
    if (ratios.reduce(math.max) / ratios.reduce(math.min) > 1.15) {
      return const PlateMotion();
    }
    final times = track
        .map((s) => (s.at - track.first.at).inMicroseconds / 1e6)
        .toList();
    double slope(List<double> values) {
      final mt = times.reduce((a, b) => a + b) / times.length;
      final mv = values.reduce((a, b) => a + b) / values.length;
      var numerator = 0.0, denominator = 0.0;
      for (var i = 0; i < times.length; i++) {
        numerator += (times[i] - mt) * (values[i] - mv);
        denominator += math.pow(times[i] - mt, 2);
      }
      return numerator / denominator;
    }

    final dx = slope(track.map((s) => s.box.cx).toList());
    final dy = slope(track.map((s) => s.box.cy).toList());
    final rate = slope(track.map((s) => math.log(s.box.area) / 2).toList());
    if (![dx, dy, rate].every((v) => v.isFinite && v.abs() <= 5)) {
      return const PlateMotion();
    }
    var direction = 'unknown';
    final changes = <double>[];
    for (var i = 1; i < track.length; i++) {
      changes.add(math.log(track[i].box.area / track[i - 1].box.area) / 2);
    }
    if (rate > .04 &&
        changes.where((v) => v > .01).length >= 3 &&
        changes.every((v) => v > -.01)) {
      direction = 'approaching';
    } else if (rate < -.04 &&
        changes.where((v) => v < -.01).length >= 3 &&
        changes.every((v) => v < .01)) {
      direction = 'receding';
    } else if (rate.abs() < .015 &&
        math.sqrt(dx * dx + dy * dy) < .01 &&
        changes.every((v) => v.abs() < .02)) {
      direction = 'stationary';
    }
    if (direction == 'unknown') return const PlateMotion();
    return PlateMotion(
      direction: direction,
      dx: dx,
      dy: dy,
      scaleRate: rate,
      samples: track.length,
      spanSeconds: span,
    );
  }
}
