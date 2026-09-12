import 'dart:math' as math;

import '../models/hand_tracking_models.dart';
import '../models/tracking_models.dart';

/// Detects a likely end-of-utterance pause from consecutive hand coordinates.
///
/// This is only a boundary detector. It does not add motion, velocity, or
/// acceleration to [LandmarkFrame]. A real pause can be part of a sign, so the
/// detector requires visible tracking, a previously observed movement, and a
/// sustained pause before it finishes anything.
class UtteranceStillnessDetector {
  UtteranceStillnessDetector({
    this.stillnessThreshold = 0.014,
    this.activityThreshold = 0.022,
    this.pauseDuration = const Duration(milliseconds: 650),
    this.minimumCaptureDuration = const Duration(milliseconds: 450),
  });

  /// Maximum average x/y landmark displacement considered still per frame.
  /// This admits ordinary webcam landmark jitter without treating it as an
  /// endless new sign motion.
  final double stillnessThreshold;

  /// Average displacement that proves the signer has started moving.
  final double activityThreshold;

  /// How long the hands must remain still before an automatic finish.
  final Duration pauseDuration;

  /// Prevents a newly started capture from ending immediately.
  final Duration minimumCaptureDuration;

  LandmarkFrame? _previousFrame;
  DateTime? _captureStartedAt;
  DateTime? _stillSince;
  bool _activityObserved = false;

  /// Returns true once the current frame completes an automatic pause.
  bool update(LandmarkFrame frame) {
    if (!_isUsable(frame)) {
      _previousFrame = null;
      // Losing the hands after movement is also a useful end signal. This
      // lets a signer finish by lowering their hands or briefly leaving the
      // frame; the next visible hand frame automatically starts a new buffer.
      if (_activityObserved && _captureStartedAt != null) {
        _stillSince ??= frame.timestamp;
        final startedAt = _captureStartedAt!;
        final stillSince = _stillSince!;
        return frame.timestamp.difference(startedAt) >=
                minimumCaptureDuration &&
            frame.timestamp.difference(stillSince) >= pauseDuration;
      }
      _stillSince = null;
      return false;
    }

    _captureStartedAt ??= frame.timestamp;
    final previous = _previousFrame;
    _previousFrame = frame;
    if (previous == null) return false;

    final displacement = _averageHandDisplacement(previous, frame);
    if (displacement == null) {
      _stillSince = null;
      return false;
    }

    if (displacement >= activityThreshold) {
      _activityObserved = true;
      _stillSince = null;
      return false;
    }

    if (displacement > stillnessThreshold) {
      _stillSince = null;
      return false;
    }

    _stillSince ??= frame.timestamp;
    final startedAt = _captureStartedAt;
    final stillSince = _stillSince;
    if (startedAt == null || stillSince == null || !_activityObserved) {
      return false;
    }

    final captureDuration = frame.timestamp.difference(startedAt);
    final stillDuration = frame.timestamp.difference(stillSince);
    return captureDuration >= minimumCaptureDuration &&
        stillDuration >= pauseDuration;
  }

  void reset() {
    _previousFrame = null;
    _captureStartedAt = null;
    _stillSince = null;
    _activityObserved = false;
  }

  bool _isUsable(LandmarkFrame frame) {
    if (frame.trackingConfidence < 0.5 || frame.hands.isEmpty) return false;
    final subject = frame.subjectTracking;
    if (subject != null && (!subject.locked || !subject.visible)) return false;
    return frame.hands.every((hand) => hand.landmarks.length >= 21);
  }

  double? _averageHandDisplacement(
    LandmarkFrame previous,
    LandmarkFrame current,
  ) {
    final previousHands = _handsBySide(previous);
    final currentHands = _handsBySide(current);
    if (previousHands.length != currentHands.length ||
        !previousHands.keys.every(currentHands.containsKey)) {
      return null;
    }

    var total = 0.0;
    var pointCount = 0;
    for (final side in previousHands.keys) {
      final oldLandmarks = previousHands[side]!;
      final newLandmarks = currentHands[side]!;
      if (oldLandmarks.length != newLandmarks.length) return null;
      for (var index = 0; index < oldLandmarks.length; index += 1) {
        final oldPoint = oldLandmarks[index];
        final newPoint = newLandmarks[index];
        if (oldPoint.visibility < 0.35 || newPoint.visibility < 0.35) {
          continue;
        }
        final dx = newPoint.x - oldPoint.x;
        final dy = newPoint.y - oldPoint.y;
        total += math.sqrt(dx * dx + dy * dy);
        pointCount += 1;
      }
    }
    return pointCount == 0 ? null : total / pointCount;
  }

  Map<Handedness, List<HandLandmark>> _handsBySide(LandmarkFrame frame) => {
    for (final hand in frame.hands) hand.handedness: hand.landmarks,
  };
}
