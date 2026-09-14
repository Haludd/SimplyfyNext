import 'dart:math' as math;

import '../models/tracking_models.dart';

/// Matches a short, body-relative landmark sequence against the examples a
/// person recorded on this device.
///
/// This is deliberately a personal-template matcher, not a replacement for
/// the shipped 250-word ONNX model. It is useful for names, household terms,
/// and other small private vocabularies, while keeping every landmark local.
final class PersonalSignMatcher {
  const PersonalSignMatcher({
    this.resampledFrameCount = 12,
    this.maximumDistance = .25,
    this.minimumConfidence = .75,
    this.minimumMargin = .08,
  }) : assert(resampledFrameCount > 1),
       assert(maximumDistance > 0 && maximumDistance <= 1),
       assert(minimumConfidence > 0 && minimumConfidence <= 1),
       assert(minimumMargin >= 0 && minimumMargin < 1);

  /// Every recording is converted to this number of evenly-spaced landmark
  /// frames, so a sign performed at a different speed remains comparable.
  final int resampledFrameCount;

  /// RMS feature distance that maps to zero template confidence.
  final double maximumDistance;
  final double minimumConfidence;
  final double minimumMargin;

  PersonalSignMatch? match({
    required List<List<double>> sequence,
    required List<CustomSign> signs,
    required String language,
  }) {
    final candidate = resample(sequence);
    if (candidate == null) return null;

    final matches = <PersonalSignMatch>[];
    for (final sign in signs) {
      if (!sign.hasEnoughSamples ||
          sign.language.toUpperCase() != language.trim().toUpperCase()) {
        continue;
      }
      final templateDistances = sign.templateSequences
          .map(resample)
          .whereType<List<List<double>>>()
          .map((template) => _distance(candidate, template))
          .whereType<double>()
          .toList(growable: false);
      if (templateDistances.isEmpty) continue;
      final distance = templateDistances.reduce(
        (left, right) => left < right ? left : right,
      );
      final confidence = (1 - distance / maximumDistance)
          .clamp(0.0, 1.0)
          .toDouble();
      matches.add(
        PersonalSignMatch(
          label: sign.label,
          confidence: confidence,
          distance: distance,
          sampleCount: sign.sampleCount,
        ),
      );
    }

    if (matches.isEmpty) return null;
    matches.sort((left, right) => right.confidence.compareTo(left.confidence));
    final best = matches.first;
    final runnerUp = matches.length > 1 ? matches[1] : null;
    if (best.confidence < minimumConfidence ||
        (runnerUp != null &&
            best.confidence - runnerUp.confidence < minimumMargin)) {
      return null;
    }
    return best;
  }

  /// Returns fixed-length, linearly interpolated feature frames. It returns
  /// null instead of inventing missing coordinates when a capture is too
  /// short, malformed, or changes vector layout part-way through recording.
  List<List<double>>? resample(List<List<double>> sequence) {
    if (sequence.isEmpty || sequence.first.isEmpty) return null;
    final width = sequence.first.length;
    if (sequence.any((frame) => frame.length != width || !_isFinite(frame))) {
      return null;
    }
    if (sequence.length == 1) {
      return List<List<double>>.generate(
        resampledFrameCount,
        (_) => List<double>.unmodifiable(sequence.single),
        growable: false,
      );
    }
    return List<List<double>>.generate(resampledFrameCount, (outputIndex) {
      final position =
          outputIndex * (sequence.length - 1) / (resampledFrameCount - 1);
      final lower = position.floor();
      final upper = position.ceil();
      final progress = position - lower;
      final from = sequence[lower];
      final to = sequence[upper];
      return List<double>.generate(
        width,
        (featureIndex) =>
            from[featureIndex] +
            (to[featureIndex] - from[featureIndex]) * progress,
        growable: false,
      );
    }, growable: false);
  }

  double? _distance(List<List<double>> left, List<List<double>> right) {
    if (left.length != right.length || left.isEmpty) return null;
    final width = math.min(left.first.length, right.first.length);
    // Hands (126 values) and torso pose (44 values) are stable, useful
    // personal-sign signals. Face/emotion slots are intentionally excluded:
    // they would make a user’s template sensitive to expression and lighting.
    final comparedWidth = math.min(width, 170);
    if (comparedWidth == 0 ||
        left.any((frame) => frame.length < comparedWidth) ||
        right.any((frame) => frame.length < comparedWidth)) {
      return null;
    }
    var total = 0.0;
    var count = 0;
    for (var frameIndex = 0; frameIndex < left.length; frameIndex += 1) {
      for (
        var featureIndex = 0;
        featureIndex < comparedWidth;
        featureIndex += 1
      ) {
        final delta =
            left[frameIndex][featureIndex] - right[frameIndex][featureIndex];
        total += delta * delta;
        count += 1;
      }
    }
    return count == 0 ? null : math.sqrt(total / count);
  }

  bool _isFinite(List<double> frame) => frame.every((value) => value.isFinite);
}

final class PersonalSignMatch {
  const PersonalSignMatch({
    required this.label,
    required this.confidence,
    required this.distance,
    required this.sampleCount,
  });

  final String label;
  final double confidence;
  final double distance;
  final int sampleCount;
}
