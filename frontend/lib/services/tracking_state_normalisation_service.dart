/// Tracking-state ideas are independently reimplemented from the
/// MIT-licensed depthai-hand-tracker reference described by PLN T1.4. No
/// source code is copied or imported from that project.
library;

import 'dart:math' as math;

import '../models/face_tracking_models.dart';
import '../models/hand_tracking_models.dart';
import '../models/state_normalisation_models.dart';
import '../models/tracking_models.dart';

/// Tunable choices for the 30 FPS state and normalisation stages.
///
/// Stage 1/2 owns the raw schema. These values only control derived Stage 3/4
/// results and never alter Harold's raw confidence or coordinate fields.
class TrackingStateNormalisationConfig {
  const TrackingStateNormalisationConfig({
    this.confidenceThreshold = 0.5,
    this.minimumTrackingQuality = 0.5,
    this.handednessDecisionThreshold = 0.6,
    this.handednessMismatchPenalty = 0.5,
    this.maximumHandMatchDistance = 0.35,
    this.trackExpiryFrames = 15,
    this.poseQualityIndices = const <int>[11, 12, 13, 14, 15, 16, 23, 24],
    this.expectedHandLandmarkCount = 21,
    this.maximumTemporalGap = const Duration(milliseconds: 250),
    this.normalisationAnchorTimeConstant = const Duration(milliseconds: 250),
    this.maximumNormalisationAnchorAge = const Duration(milliseconds: 500),
    this.minimumShoulderWidth = 0.0001,
    this.smoothingCutoffHz = 6,
  }) : assert(confidenceThreshold >= 0 && confidenceThreshold <= 1),
       assert(minimumTrackingQuality >= 0 && minimumTrackingQuality <= 1),
       assert(
         handednessDecisionThreshold > 0.5 && handednessDecisionThreshold <= 1,
       ),
       assert(handednessMismatchPenalty >= 0),
       assert(maximumHandMatchDistance > 0),
       assert(trackExpiryFrames >= 0),
       assert(expectedHandLandmarkCount > 0),
       assert(minimumShoulderWidth > 0),
       assert(smoothingCutoffHz > 0);

  final double confidenceThreshold;
  final double minimumTrackingQuality;
  final double handednessDecisionThreshold;
  final double handednessMismatchPenalty;
  final double maximumHandMatchDistance;
  final int trackExpiryFrames;
  final List<int> poseQualityIndices;
  final int expectedHandLandmarkCount;
  final Duration maximumTemporalGap;
  final Duration normalisationAnchorTimeConstant;
  final Duration maximumNormalisationAnchorAge;
  final double minimumShoulderWidth;
  final double smoothingCutoffHz;
}

/// Derives current tracking health and stable per-hand state from Harold's
/// canonical Stage 1/2 [LandmarkFrame].
///
/// Raw hands, points, confidence values, and coordinates are never replaced.
/// The result is attached to [LandmarkFrame.trackingState].
class TrackingStateService {
  TrackingStateService({
    this.config = const TrackingStateNormalisationConfig(),
  });

  final TrackingStateNormalisationConfig config;
  final Map<String, _HandTrack> _tracks = <String, _HandTrack>{};

  DateTime? _lastTimestamp;
  bool? _lastSubjectLocked;
  var _hasProcessedFrame = false;
  var _sequence = 0;
  var _nextTrackId = 1;
  var _trackingEpoch = 0;

  LandmarkFrame process(LandmarkFrame input) {
    _prepareFor(input);

    var handStates = _assignTracks(input.hands);
    handStates = _addMeasuredPoseWristSubstitutes(
      input.hands,
      handStates,
      input.poseLandmarks,
    );

    final hasShoulders = _hasUsableShoulderPair(
      input.leftShoulder,
      input.rightShoulder,
    );
    final hasHand = input.hands.any(_handHasUsablePoint);
    final hasPose = input.poseLandmarks.any(_isUsablePose);
    final hasFace =
        input.faceUpperLandmarks.any(_isUsableFace) ||
        input.faceMouthLandmarks.any(_isUsableFace);
    final hasAnyLandmark = hasHand || hasPose || hasFace;
    final handQuality = _handTrackingQuality(input.hands);
    final assessedQuality = _trackingQuality(input.poseLandmarks, handQuality);
    final hasUncertainHandedness = handStates.any(
      (state) => state.handednessUncertain,
    );

    final issues = <TrackingIssue>{};
    if (!hasAnyLandmark) issues.add(TrackingIssue.noLandmarks);
    if (!hasHand) issues.add(TrackingIssue.noHands);
    if (!hasShoulders) issues.add(TrackingIssue.missingShoulders);
    if (_hasLowConfidenceOrInvalidPoint(input)) {
      issues.add(TrackingIssue.lowConfidence);
    }
    if (hasUncertainHandedness) {
      issues.add(TrackingIssue.handednessUncertain);
    }

    final subject = input.subjectTracking;
    final subjectIsLockedAndVisible =
        subject?.locked == true && subject?.visible == true;
    final lockedSubjectIsMissing =
        subject?.locked == true && subject?.visible == false;
    final status = !hasAnyLandmark || lockedSubjectIsMissing
        ? TrackingStatus.absent
        : subjectIsLockedAndVisible &&
              hasShoulders &&
              hasHand &&
              handQuality >= config.minimumTrackingQuality &&
              assessedQuality >= config.minimumTrackingQuality
        ? TrackingStatus.tracked
        : TrackingStatus.degraded;

    return input.copyWith(
      trackingState: TrackingStateResult(
        status: status,
        assessedQuality: assessedQuality,
        issues: issues.toList(growable: false),
        canNormalise: hasShoulders,
        trackingEpoch: _trackingEpoch,
        hands: handStates,
      ),
      // A Stage 3 pass invalidates any derived Stage 4 result that may have
      // been attached to this object by an earlier caller.
      normalisation: null,
    );
  }

  void reset() => _startNewEpoch();

  void _prepareFor(LandmarkFrame input) {
    if (_hasProcessedFrame) {
      final elapsed = input.timestamp.difference(_lastTimestamp!);
      final lostSubjectLock =
          _lastSubjectLocked == true && input.subjectTracking?.locked == false;
      if (elapsed <= Duration.zero ||
          elapsed > config.maximumTemporalGap ||
          lostSubjectLock) {
        _startNewEpoch();
      }
    }

    _hasProcessedFrame = true;
    _lastTimestamp = input.timestamp;
    _lastSubjectLocked = input.subjectTracking?.locked;
    _sequence += 1;
    _tracks.removeWhere(
      (_, track) =>
          _sequence - track.lastSeenSequence > config.trackExpiryFrames,
    );
  }

  void _startNewEpoch() {
    _tracks.clear();
    _lastTimestamp = null;
    _lastSubjectLocked = null;
    _hasProcessedFrame = false;
    _sequence = 0;
    _nextTrackId = 1;
    _trackingEpoch += 1;
  }

  List<TrackedHandState> _assignTracks(List<TrackedHand> hands) {
    if (hands.isEmpty) return const <TrackedHandState>[];

    final anchors = hands.map(_handAnchor).toList(growable: false);
    final assignments = List<_HandTrack?>.filled(hands.length, null);
    final usedTrackIds = <String>{};

    final spatialAssignments = _bestSpatialAssignments(
      hands,
      anchors,
      usedTrackIds,
    );
    for (final assignment in spatialAssignments.entries) {
      assignments[assignment.key] = assignment.value;
      usedTrackIds.add(assignment.value.id);
    }

    for (var index = 0; index < hands.length; index += 1) {
      if (assignments[index] != null) continue;
      final observed = hands[index].handedness;
      if (observed == Handedness.unknown) continue;
      final labelMatches = _tracks.values
          .where(
            (track) =>
                !usedTrackIds.contains(track.id) &&
                track.settledHandedness == observed,
          )
          .toList(growable: false);
      if (labelMatches.length == 1) {
        assignments[index] = labelMatches.single;
        usedTrackIds.add(labelMatches.single.id);
      }
    }

    final initialStates = <TrackedHandState>[];
    for (var index = 0; index < hands.length; index += 1) {
      final hand = hands[index];
      final track = assignments[index] ?? _createTrack();
      track.lastSeenSequence = _sequence;
      if (anchors[index] != null) track.lastAnchor = anchors[index];
      _updateHandedness(track, hand.handedness, hand.confidence);
      initialStates.add(
        TrackedHandState(
          sourceHandIndex: index,
          trackId: track.id,
          stableHandedness: track.settledHandedness,
          rightHandednessRunningAverage: track.runningRightProbability,
          handednessObservationCount: track.handednessObservationCount,
          handednessUncertain: track.settledHandedness == Handedness.unknown,
        ),
      );
    }

    final rawCounts = _handednessCounts(hands.map((hand) => hand.handedness));
    final stableCounts = _handednessCounts(
      initialStates.map((state) => state.stableHandedness),
    );
    return initialStates
        .map((state) {
          final raw = hands[state.sourceHandIndex].handedness;
          final stable = state.stableHandedness;
          return TrackedHandState(
            sourceHandIndex: state.sourceHandIndex,
            trackId: state.trackId,
            stableHandedness: stable,
            rightHandednessRunningAverage: state.rightHandednessRunningAverage,
            handednessObservationCount: state.handednessObservationCount,
            handednessUncertain:
                state.handednessUncertain ||
                (raw != Handedness.unknown && (rawCounts[raw] ?? 0) > 1) ||
                (stable != Handedness.unknown &&
                    (stableCounts[stable] ?? 0) > 1),
          );
        })
        .toList(growable: false);
  }

  Map<int, _HandTrack> _bestSpatialAssignments(
    List<TrackedHand> hands,
    List<LandmarkCoordinates?> anchors,
    Set<String> alreadyUsedTrackIds,
  ) {
    final handIndices = <int>[
      for (var index = 0; index < hands.length; index += 1)
        if (anchors[index] != null) index,
    ];
    final tracks = _tracks.values
        .where(
          (track) =>
              !alreadyUsedTrackIds.contains(track.id) &&
              track.lastAnchor != null,
        )
        .toList(growable: false);
    if (handIndices.isEmpty || tracks.isEmpty) {
      return const <int, _HandTrack>{};
    }

    var bestMatchCount = -1;
    var bestCost = double.infinity;
    var best = <int, _HandTrack>{};

    void search(
      int offset,
      Map<int, _HandTrack> selected,
      Set<String> usedIds,
      double cost,
    ) {
      if (offset == handIndices.length) {
        if (selected.length > bestMatchCount ||
            (selected.length == bestMatchCount && cost < bestCost)) {
          bestMatchCount = selected.length;
          bestCost = cost;
          best = Map<int, _HandTrack>.from(selected);
        }
        return;
      }

      final handIndex = handIndices[offset];
      search(offset + 1, selected, usedIds, cost);
      for (final track in tracks) {
        if (usedIds.contains(track.id)) continue;
        final distance = _distance2d(anchors[handIndex]!, track.lastAnchor!);
        if (distance > config.maximumHandMatchDistance) continue;
        selected[handIndex] = track;
        usedIds.add(track.id);
        search(
          offset + 1,
          selected,
          usedIds,
          cost + _handMatchCost(hands[handIndex], track, distance),
        );
        usedIds.remove(track.id);
        selected.remove(handIndex);
      }
    }

    search(0, <int, _HandTrack>{}, <String>{}, 0);
    return best;
  }

  double _handMatchCost(TrackedHand hand, _HandTrack track, double distance) {
    final observed = hand.handedness;
    final isConfidentMismatch =
        hand.confidence >= config.handednessDecisionThreshold &&
        observed != Handedness.unknown &&
        track.settledHandedness != Handedness.unknown &&
        observed != track.settledHandedness;
    return distance +
        (isConfidentMismatch ? config.handednessMismatchPenalty : 0);
  }

  _HandTrack _createTrack() {
    final id = 'hand-${_nextTrackId++}';
    final track = _HandTrack(id: id, lastSeenSequence: _sequence);
    _tracks[id] = track;
    return track;
  }

  void _updateHandedness(
    _HandTrack track,
    Handedness observed,
    double confidence,
  ) {
    if (observed == Handedness.unknown) return;
    final boundedConfidence = _unit(confidence);
    final rightProbability = observed == Handedness.right
        ? boundedConfidence
        : 1 - boundedConfidence;
    track.rightProbabilityTotal += rightProbability;
    track.handednessObservationCount += 1;

    final average = track.runningRightProbability;
    final lowerThreshold = 1 - config.handednessDecisionThreshold;
    if (track.settledHandedness == Handedness.unknown) {
      if (average >= config.handednessDecisionThreshold) {
        track.settledHandedness = Handedness.right;
      } else if (average <= lowerThreshold) {
        track.settledHandedness = Handedness.left;
      }
    } else if (track.settledHandedness == Handedness.right &&
        average <= lowerThreshold) {
      track.settledHandedness = Handedness.left;
    } else if (track.settledHandedness == Handedness.left &&
        average >= config.handednessDecisionThreshold) {
      track.settledHandedness = Handedness.right;
    }
  }

  List<TrackedHandState> _addMeasuredPoseWristSubstitutes(
    List<TrackedHand> hands,
    List<TrackedHandState> states,
    List<PoseLandmark> pose,
  ) => states
      .map((state) {
        final hand = hands[state.sourceHandIndex];
        final wrist = hand.landmarks.isEmpty ? null : hand.landmarks.first;
        if (_isUsableHand(wrist) || state.handednessUncertain) return state;

        final side = state.stableHandedness != Handedness.unknown
            ? state.stableHandedness
            : hand.handedness;
        final poseIndex = switch (side) {
          Handedness.left => 15,
          Handedness.right => 16,
          Handedness.unknown => null,
        };
        if (poseIndex == null) return state;
        final poseWrist = _poseAt(pose, poseIndex);
        if (!_isUsablePose(poseWrist)) return state;

        return TrackedHandState(
          sourceHandIndex: state.sourceHandIndex,
          trackId: state.trackId,
          stableHandedness: state.stableHandedness,
          rightHandednessRunningAverage: state.rightHandednessRunningAverage,
          handednessObservationCount: state.handednessObservationCount,
          handednessUncertain: state.handednessUncertain,
          poseWristSubstituteCoordinates: LandmarkCoordinates(
            x: poseWrist!.x,
            y: poseWrist.y,
            z: poseWrist.z,
          ),
          poseWristSubstituteVisibility: poseWrist.visibility,
        );
      })
      .toList(growable: false);

  Map<Handedness, int> _handednessCounts(Iterable<Handedness> values) {
    final counts = <Handedness, int>{};
    for (final value in values) {
      counts[value] = (counts[value] ?? 0) + 1;
    }
    return counts;
  }

  LandmarkCoordinates? _handAnchor(TrackedHand hand) {
    if (hand.landmarks.isEmpty) return null;
    final wrist = hand.landmarks.first;
    if (_isUsableHand(wrist)) {
      return LandmarkCoordinates(x: wrist.x, y: wrist.y, z: wrist.z);
    }

    var count = 0;
    var x = 0.0;
    var y = 0.0;
    for (final point in hand.landmarks) {
      if (!_isUsableHand(point)) continue;
      x += point.x;
      y += point.y;
      count += 1;
    }
    return count == 0 ? null : LandmarkCoordinates(x: x / count, y: y / count);
  }

  bool _handHasUsablePoint(TrackedHand hand) =>
      hand.landmarks.any(_isUsableHand);

  bool _hasUsableShoulderPair(NormalizedPoint? left, NormalizedPoint? right) {
    if (!_isUsableNormalized(left) || !_isUsableNormalized(right)) {
      return false;
    }
    return _distance2d(
          LandmarkCoordinates(x: left!.x, y: left.y),
          LandmarkCoordinates(x: right!.x, y: right.y),
        ) >=
        config.minimumShoulderWidth;
  }

  bool _hasLowConfidenceOrInvalidPoint(LandmarkFrame frame) =>
      frame.hands
          .expand((hand) => hand.landmarks)
          .any((point) => !_isUsableHand(point)) ||
      frame.poseLandmarks.any((point) => !_isUsablePose(point)) ||
      frame.faceUpperLandmarks.any((point) => !_isUsableFace(point)) ||
      frame.faceMouthLandmarks.any((point) => !_isUsableFace(point));

  double _trackingQuality(List<PoseLandmark> pose, double handQuality) {
    var poseQuality = 0.0;
    for (final index in config.poseQualityIndices) {
      final point = _poseAt(pose, index);
      if (_isUsablePose(point)) poseQuality += _unit(point!.visibility);
    }
    poseQuality = config.poseQualityIndices.isEmpty
        ? 0
        : poseQuality / config.poseQualityIndices.length;
    return _unit((poseQuality + handQuality) / 2);
  }

  double _handTrackingQuality(List<TrackedHand> hands) {
    if (hands.isEmpty) return 0;
    var total = 0.0;
    for (final hand in hands) {
      var handTotal = 0.0;
      for (
        var index = 0;
        index < config.expectedHandLandmarkCount;
        index += 1
      ) {
        if (index >= hand.landmarks.length) continue;
        final point = hand.landmarks[index];
        if (_isUsableHand(point)) handTotal += _unit(point.visibility);
      }
      total += handTotal / config.expectedHandLandmarkCount;
    }
    return _unit(total / hands.length);
  }

  bool _isUsableHand(HandLandmark? point) =>
      point != null &&
      point.visibility >= config.confidenceThreshold &&
      point.x.isFinite &&
      point.y.isFinite &&
      point.z.isFinite;

  bool _isUsablePose(PoseLandmark? point) =>
      point != null &&
      point.visibility >= config.confidenceThreshold &&
      point.x.isFinite &&
      point.y.isFinite &&
      point.z.isFinite;

  bool _isUsableFace(FaceLandmark? point) =>
      point != null &&
      point.visibility >= config.confidenceThreshold &&
      point.x.isFinite &&
      point.y.isFinite &&
      point.z.isFinite;

  bool _isUsableNormalized(NormalizedPoint? point) =>
      point != null &&
      point.visibility >= config.confidenceThreshold &&
      point.x.isFinite &&
      point.y.isFinite &&
      point.z.isFinite;
}

/// Creates body-relative coordinates and temporal derivatives without
/// changing the canonical Stage 1/2 landmark fields.
class LandmarkNormalisationService {
  LandmarkNormalisationService({
    this.config = const TrackingStateNormalisationConfig(),
  });

  final TrackingStateNormalisationConfig config;
  final Map<String, _PointHistory> _history = <String, _PointHistory>{};
  final Set<String> _seenHistoryKeys = <String>{};

  _BodyAnchor? _anchor;
  DateTime? _lastTimestamp;
  int? _trackingEpoch;
  var _hasProcessedFrame = false;

  LandmarkFrame process(LandmarkFrame input) {
    _prepareFor(input);

    final measurement = _shoulderMeasurement(
      input.leftShoulder,
      input.rightShoulder,
    );
    if (measurement != null) _updateAnchor(measurement, input.timestamp);

    var anchorIsStale = measurement == null && _anchor != null;
    if (_anchor != null &&
        input.timestamp.difference(_anchor!.measuredAt) >
            config.maximumNormalisationAnchorAge) {
      _anchor = null;
      anchorIsStale = false;
    }

    _seenHistoryKeys.clear();
    final pose = input.poseLandmarks
        .map(
          (point) => _normaliseObservation(
            _Observation.fromPose(point),
            key: 'pose:${point.index}',
            timestamp: input.timestamp,
            smooth: true,
          ),
        )
        .toList(growable: false);
    final faceUpper = input.faceUpperLandmarks
        .map(
          (point) => _normaliseObservation(
            _Observation.fromFace(point),
            key: 'face-upper:${point.index}',
            timestamp: input.timestamp,
            smooth: false,
          ),
        )
        .toList(growable: false);
    final faceMouth = input.faceMouthLandmarks
        .map(
          (point) => _normaliseObservation(
            _Observation.fromFace(point),
            key: 'face-mouth:${point.index}',
            timestamp: input.timestamp,
            smooth: false,
          ),
        )
        .toList(growable: false);
    final hands = input.hands
        .asMap()
        .entries
        .map(
          (entry) => _normaliseHand(
            entry.value,
            entry.key,
            input.trackingState,
            input.timestamp,
          ),
        )
        .toList(growable: false);
    _history.removeWhere((key, _) => !_seenHistoryKeys.contains(key));

    return input.copyWith(
      normalisation: NormalisationResult(
        canNormalise: _anchor != null,
        origin: _anchor?.centre,
        scale: _anchor?.shoulderWidth,
        anchorIsStale: anchorIsStale,
        poseLandmarks: pose,
        faceUpperLandmarks: faceUpper,
        faceMouthLandmarks: faceMouth,
        hands: hands,
      ),
    );
  }

  void reset() {
    _history.clear();
    _seenHistoryKeys.clear();
    _anchor = null;
    _lastTimestamp = null;
    _trackingEpoch = null;
    _hasProcessedFrame = false;
  }

  void _prepareFor(LandmarkFrame input) {
    final incomingEpoch = input.trackingState?.trackingEpoch;
    if (_hasProcessedFrame) {
      final elapsed = input.timestamp.difference(_lastTimestamp!);
      final changedEpoch =
          incomingEpoch != null &&
          _trackingEpoch != null &&
          incomingEpoch != _trackingEpoch;
      if (elapsed <= Duration.zero ||
          elapsed > config.maximumTemporalGap ||
          changedEpoch) {
        reset();
      }
    }
    _hasProcessedFrame = true;
    _lastTimestamp = input.timestamp;
    _trackingEpoch = incomingEpoch;
  }

  _ShoulderMeasurement? _shoulderMeasurement(
    NormalizedPoint? left,
    NormalizedPoint? right,
  ) {
    if (!_isUsableShoulder(left) || !_isUsableShoulder(right)) return null;
    final leftCoordinates = LandmarkCoordinates(x: left!.x, y: left.y);
    final rightCoordinates = LandmarkCoordinates(x: right!.x, y: right.y);
    final width = _distance2d(leftCoordinates, rightCoordinates);
    if (width < config.minimumShoulderWidth) return null;
    return _ShoulderMeasurement(
      centre: LandmarkCoordinates(
        x: (left.x + right.x) / 2,
        y: (left.y + right.y) / 2,
      ),
      shoulderWidth: width,
    );
  }

  void _updateAnchor(_ShoulderMeasurement measurement, DateTime timestamp) {
    final current = _anchor;
    if (current == null) {
      _anchor = _BodyAnchor(
        centre: measurement.centre,
        shoulderWidth: measurement.shoulderWidth,
        measuredAt: timestamp,
      );
      return;
    }

    final elapsedSeconds =
        timestamp.difference(current.measuredAt).inMicroseconds /
        Duration.microsecondsPerSecond;
    final timeConstantSeconds =
        config.normalisationAnchorTimeConstant.inMicroseconds /
        Duration.microsecondsPerSecond;
    final alpha = timeConstantSeconds <= 0
        ? 1.0
        : 1 - math.exp(-elapsedSeconds / timeConstantSeconds);
    _anchor = _BodyAnchor(
      centre: _lerp2d(current.centre, measurement.centre, alpha),
      shoulderWidth:
          current.shoulderWidth +
          (measurement.shoulderWidth - current.shoulderWidth) * alpha,
      measuredAt: timestamp,
    );
  }

  NormalisedHand _normaliseHand(
    TrackedHand hand,
    int sourceHandIndex,
    TrackingStateResult? trackingState,
    DateTime timestamp,
  ) {
    final handState = _handStateAt(trackingState, sourceHandIndex);
    final hasTrackedIdentity = handState != null;
    final trackId =
        handState?.trackId ??
        'untracked:${hand.handedness.name}:$sourceHandIndex';
    final canonicalWorld = _canonicaliseHandWorldCoordinates(hand);
    final points = <NormalisedLandmark>[];

    for (final entry in hand.landmarks.asMap().entries) {
      var observation = _Observation.fromHand(entry.key, entry.value);
      if (entry.key == 0 &&
          !_isUsableObservation(observation) &&
          _isUsablePoseWristSubstitute(handState)) {
        final substitute = handState!.poseWristSubstituteCoordinates!;
        observation = _Observation(
          index: 0,
          x: substitute.x,
          y: substitute.y,
          z: substitute.z ?? 0,
          visibility: handState.poseWristSubstituteVisibility!,
          source: LandmarkSource.poseWristSubstitution,
        );
      }
      points.add(
        _normaliseObservation(
          observation,
          key: 'hand:$trackId:${entry.key}',
          timestamp: timestamp,
          smooth: true,
          canonicalWorldCoordinates: canonicalWorld[entry.key],
          temporalEnabled: hasTrackedIdentity,
        ),
      );
    }

    return NormalisedHand(
      sourceHandIndex: sourceHandIndex,
      trackId: trackId,
      landmarks: points,
    );
  }

  NormalisedLandmark _normaliseObservation(
    _Observation observation, {
    required String key,
    required DateTime timestamp,
    required bool smooth,
    LandmarkCoordinates? canonicalWorldCoordinates,
    bool temporalEnabled = true,
  }) {
    final anchor = _anchor;
    if (anchor == null || !_isUsableObservation(observation)) {
      _history.remove(key);
      return NormalisedLandmark(
        index: observation.index,
        canonicalWorldCoordinates: _isUsableObservation(observation)
            ? canonicalWorldCoordinates
            : null,
        source: observation.source,
      );
    }

    final candidate = LandmarkCoordinates(
      x: (observation.x - anchor.centre.x) / anchor.shoulderWidth,
      y: (observation.y - anchor.centre.y) / anchor.shoulderWidth,
    );
    final previous = temporalEnabled ? _history[key] : null;
    final elapsedSeconds = previous == null
        ? null
        : timestamp.difference(previous.timestamp).inMicroseconds /
              Duration.microsecondsPerSecond;
    final position = smooth && previous != null && elapsedSeconds! > 0
        ? _lowPass(previous.position, candidate, elapsedSeconds)
        : candidate;

    LandmarkCoordinates? velocity;
    LandmarkCoordinates? acceleration;
    if (previous != null && elapsedSeconds! > 0) {
      velocity = _divide2d(
        _subtract2d(position, previous.position),
        elapsedSeconds,
      );
      if (previous.velocity != null) {
        acceleration = _divide2d(
          _subtract2d(velocity, previous.velocity!),
          elapsedSeconds,
        );
      }
    }

    if (temporalEnabled) {
      _history[key] = _PointHistory(
        position: position,
        velocity: velocity,
        timestamp: timestamp,
      );
      _seenHistoryKeys.add(key);
    } else {
      _history.remove(key);
    }
    return NormalisedLandmark(
      index: observation.index,
      normalisedCoordinates: position,
      velocity: velocity,
      acceleration: acceleration,
      canonicalWorldCoordinates: canonicalWorldCoordinates,
      source: observation.source,
    );
  }

  LandmarkCoordinates _lowPass(
    LandmarkCoordinates previous,
    LandmarkCoordinates current,
    double elapsedSeconds,
  ) {
    final rc = 1 / (2 * math.pi * config.smoothingCutoffHz);
    final alpha = elapsedSeconds / (rc + elapsedSeconds);
    return _lerp2d(previous, current, alpha);
  }

  Map<int, LandmarkCoordinates> _canonicaliseHandWorldCoordinates(
    TrackedHand hand,
  ) {
    if (hand.landmarks.length <= 17) {
      return const <int, LandmarkCoordinates>{};
    }
    final wrist = _usableWorldPoint(hand.landmarks[0]);
    final indexMcp = _usableWorldPoint(hand.landmarks[5]);
    final pinkyMcp = _usableWorldPoint(hand.landmarks[17]);
    if (wrist == null || indexMcp == null || pinkyMcp == null) {
      return const <int, LandmarkCoordinates>{};
    }

    final xAxis = _normalise3d(_subtract3d(indexMcp, pinkyMcp));
    final palmDirection = _subtract3d(
      _scale3d(_add3d(indexMcp, pinkyMcp), 0.5),
      wrist,
    );
    if (xAxis == null) return const <int, LandmarkCoordinates>{};
    final zAxis = _normalise3d(_cross3d(xAxis, palmDirection));
    if (zAxis == null) return const <int, LandmarkCoordinates>{};
    final yAxis = _normalise3d(_cross3d(zAxis, xAxis));
    if (yAxis == null) return const <int, LandmarkCoordinates>{};

    final result = <int, LandmarkCoordinates>{};
    for (final entry in hand.landmarks.asMap().entries) {
      final world = _usableWorldPoint(entry.value);
      if (world == null) continue;
      final relative = _subtract3d(world, wrist);
      result[entry.key] = LandmarkCoordinates(
        x: _dot3d(relative, xAxis),
        y: _dot3d(relative, yAxis),
        z: _dot3d(relative, zAxis),
      );
    }
    return result;
  }

  LandmarkCoordinates? _usableWorldPoint(HandLandmark point) {
    if (point.visibility < config.confidenceThreshold ||
        point.worldX == null ||
        point.worldY == null ||
        point.worldZ == null ||
        !point.worldX!.isFinite ||
        !point.worldY!.isFinite ||
        !point.worldZ!.isFinite) {
      return null;
    }
    return LandmarkCoordinates(
      x: point.worldX!,
      y: point.worldY!,
      z: point.worldZ!,
    );
  }

  TrackedHandState? _handStateAt(
    TrackingStateResult? state,
    int sourceHandIndex,
  ) {
    if (state == null) return null;
    for (final hand in state.hands) {
      if (hand.sourceHandIndex == sourceHandIndex) return hand;
    }
    return null;
  }

  bool _isUsablePoseWristSubstitute(TrackedHandState? state) =>
      state?.poseWristSubstituteCoordinates?.isFinite == true &&
      (state?.poseWristSubstituteVisibility ?? 0) >= config.confidenceThreshold;

  bool _isUsableObservation(_Observation point) =>
      point.visibility >= config.confidenceThreshold &&
      point.x.isFinite &&
      point.y.isFinite &&
      point.z.isFinite;

  bool _isUsableShoulder(NormalizedPoint? point) =>
      point != null &&
      point.visibility >= config.confidenceThreshold &&
      point.x.isFinite &&
      point.y.isFinite &&
      point.z.isFinite;
}

/// Synchronous facade used between Harold's Stage 1/2 stream and the future
/// segmentation stage. It performs no camera, MediaPipe, network, UI,
/// segmentation, or classification work.
class TrackingStateNormalisationService {
  TrackingStateNormalisationService({
    TrackingStateNormalisationConfig config =
        const TrackingStateNormalisationConfig(),
  }) : trackingState = TrackingStateService(config: config),
       normalisation = LandmarkNormalisationService(config: config);

  final TrackingStateService trackingState;
  final LandmarkNormalisationService normalisation;

  LandmarkFrame process(LandmarkFrame input) =>
      normalisation.process(trackingState.process(input));

  void reset() {
    trackingState.reset();
    normalisation.reset();
  }
}

class _HandTrack {
  _HandTrack({required this.id, required this.lastSeenSequence});

  final String id;
  int lastSeenSequence;
  LandmarkCoordinates? lastAnchor;
  double rightProbabilityTotal = 0;
  int handednessObservationCount = 0;
  Handedness settledHandedness = Handedness.unknown;

  double get runningRightProbability => handednessObservationCount == 0
      ? 0.5
      : rightProbabilityTotal / handednessObservationCount;
}

class _Observation {
  const _Observation({
    required this.index,
    required this.x,
    required this.y,
    required this.z,
    required this.visibility,
    this.source = LandmarkSource.mediaPipe,
  });

  factory _Observation.fromHand(int index, HandLandmark point) => _Observation(
    index: index,
    x: point.x,
    y: point.y,
    z: point.z,
    visibility: point.visibility,
  );

  factory _Observation.fromPose(PoseLandmark point) => _Observation(
    index: point.index,
    x: point.x,
    y: point.y,
    z: point.z,
    visibility: point.visibility,
  );

  factory _Observation.fromFace(FaceLandmark point) => _Observation(
    index: point.index,
    x: point.x,
    y: point.y,
    z: point.z,
    visibility: point.visibility,
  );

  final int index;
  final double x;
  final double y;
  final double z;
  final double visibility;
  final LandmarkSource source;
}

class _ShoulderMeasurement {
  const _ShoulderMeasurement({
    required this.centre,
    required this.shoulderWidth,
  });

  final LandmarkCoordinates centre;
  final double shoulderWidth;
}

class _BodyAnchor {
  const _BodyAnchor({
    required this.centre,
    required this.shoulderWidth,
    required this.measuredAt,
  });

  final LandmarkCoordinates centre;
  final double shoulderWidth;
  final DateTime measuredAt;
}

class _PointHistory {
  const _PointHistory({
    required this.position,
    required this.velocity,
    required this.timestamp,
  });

  final LandmarkCoordinates position;
  final LandmarkCoordinates? velocity;
  final DateTime timestamp;
}

PoseLandmark? _poseAt(List<PoseLandmark> points, int index) {
  for (final point in points) {
    if (point.index == index) return point;
  }
  return null;
}

double _unit(double value) => value.clamp(0.0, 1.0).toDouble();

double _distance2d(LandmarkCoordinates left, LandmarkCoordinates right) =>
    math.sqrt(math.pow(left.x - right.x, 2) + math.pow(left.y - right.y, 2));

LandmarkCoordinates _lerp2d(
  LandmarkCoordinates from,
  LandmarkCoordinates to,
  double amount,
) => LandmarkCoordinates(
  x: from.x + (to.x - from.x) * amount,
  y: from.y + (to.y - from.y) * amount,
);

LandmarkCoordinates _subtract2d(
  LandmarkCoordinates left,
  LandmarkCoordinates right,
) => LandmarkCoordinates(x: left.x - right.x, y: left.y - right.y);

LandmarkCoordinates _divide2d(LandmarkCoordinates value, double divisor) =>
    LandmarkCoordinates(x: value.x / divisor, y: value.y / divisor);

LandmarkCoordinates _add3d(
  LandmarkCoordinates left,
  LandmarkCoordinates right,
) => LandmarkCoordinates(
  x: left.x + right.x,
  y: left.y + right.y,
  z: (left.z ?? 0) + (right.z ?? 0),
);

LandmarkCoordinates _subtract3d(
  LandmarkCoordinates left,
  LandmarkCoordinates right,
) => LandmarkCoordinates(
  x: left.x - right.x,
  y: left.y - right.y,
  z: (left.z ?? 0) - (right.z ?? 0),
);

LandmarkCoordinates _scale3d(LandmarkCoordinates value, double scale) =>
    LandmarkCoordinates(
      x: value.x * scale,
      y: value.y * scale,
      z: (value.z ?? 0) * scale,
    );

LandmarkCoordinates _cross3d(
  LandmarkCoordinates left,
  LandmarkCoordinates right,
) => LandmarkCoordinates(
  x: left.y * (right.z ?? 0) - (left.z ?? 0) * right.y,
  y: (left.z ?? 0) * right.x - left.x * (right.z ?? 0),
  z: left.x * right.y - left.y * right.x,
);

double _dot3d(LandmarkCoordinates left, LandmarkCoordinates right) =>
    left.x * right.x + left.y * right.y + (left.z ?? 0) * (right.z ?? 0);

LandmarkCoordinates? _normalise3d(LandmarkCoordinates value) {
  final length = math.sqrt(_dot3d(value, value));
  return length <= 1e-12 ? null : _scale3d(value, 1 / length);
}
