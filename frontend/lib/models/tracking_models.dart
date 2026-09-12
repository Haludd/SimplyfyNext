import 'dart:math' as math;

import 'hand_coordinate_analysis.dart';
import 'hand_tracking_models.dart';
import 'face_tracking_models.dart';
import 'state_normalisation_models.dart';

class NormalizedPoint {
  const NormalizedPoint({
    required this.x,
    required this.y,
    this.z = 0,
    this.visibility = 1,
  });

  final double x;
  final double y;
  final double z;
  final double visibility;

  bool get isVisible => visibility >= 0.5;
}

class LandmarkFrame {
  const LandmarkFrame({
    required this.timestamp,
    this.leftShoulder,
    this.rightShoulder,
    this.leftWrist,
    this.rightWrist,
    this.leftHandVisible = false,
    this.rightHandVisible = false,
    this.lightingScore = 0.9,
    this.trackingConfidence = 0.98,
    this.featureVector = const <double>[],
    this.hands = const <TrackedHand>[],
    this.handCoordinateAnalysis = const <HandCoordinateAnalysis>[],
    this.faceExpression,
    this.poseLandmarks = const <PoseLandmark>[],
    this.faceUpperLandmarks = const <FaceLandmark>[],
    this.faceMouthLandmarks = const <FaceLandmark>[],
    this.subjectTracking,
    this.trackingState,
    this.normalisation,
  });

  static const Object _notProvided = Object();

  final DateTime timestamp;
  final NormalizedPoint? leftShoulder;
  final NormalizedPoint? rightShoulder;
  final NormalizedPoint? leftWrist;
  final NormalizedPoint? rightWrist;
  final bool leftHandVisible;
  final bool rightHandVisible;
  final double lightingScore;
  final double trackingConfidence;
  final List<double> featureVector;
  final List<TrackedHand> hands;
  final List<HandCoordinateAnalysis> handCoordinateAnalysis;
  final FaceExpressionFeatures? faceExpression;
  final List<PoseLandmark> poseLandmarks;
  final List<FaceLandmark> faceUpperLandmarks;
  final List<FaceLandmark> faceMouthLandmarks;
  final SubjectTracking? subjectTracking;

  /// Runtime-only Stage 3 result. It is deliberately excluded from [toJson]
  /// so the raw LandmarkFrame wire schema stays unchanged.
  final TrackingStateResult? trackingState;

  /// Runtime-only Stage 4 result. It is deliberately excluded from [toJson]
  /// so the raw LandmarkFrame wire schema stays unchanged.
  final NormalisationResult? normalisation;

  bool get shouldersVisible =>
      leftShoulder?.isVisible == true && rightShoulder?.isVisible == true;
  bool get armsVisible =>
      leftWrist?.isVisible == true && rightWrist?.isVisible == true;
  bool get handsVisible =>
      hands.isNotEmpty || (leftHandVisible && rightHandVisible);

  /// Returns a frame with selected values replaced while preserving all other
  /// raw landmark values and derived pipeline state.
  LandmarkFrame copyWith({
    DateTime? timestamp,
    Object? leftShoulder = _notProvided,
    Object? rightShoulder = _notProvided,
    Object? leftWrist = _notProvided,
    Object? rightWrist = _notProvided,
    bool? leftHandVisible,
    bool? rightHandVisible,
    double? lightingScore,
    double? trackingConfidence,
    List<double>? featureVector,
    List<TrackedHand>? hands,
    List<HandCoordinateAnalysis>? handCoordinateAnalysis,
    Object? faceExpression = _notProvided,
    List<PoseLandmark>? poseLandmarks,
    List<FaceLandmark>? faceUpperLandmarks,
    List<FaceLandmark>? faceMouthLandmarks,
    Object? subjectTracking = _notProvided,
    Object? trackingState = _notProvided,
    Object? normalisation = _notProvided,
  }) => LandmarkFrame(
    timestamp: timestamp ?? this.timestamp,
    leftShoulder: identical(leftShoulder, _notProvided)
        ? this.leftShoulder
        : leftShoulder as NormalizedPoint?,
    rightShoulder: identical(rightShoulder, _notProvided)
        ? this.rightShoulder
        : rightShoulder as NormalizedPoint?,
    leftWrist: identical(leftWrist, _notProvided)
        ? this.leftWrist
        : leftWrist as NormalizedPoint?,
    rightWrist: identical(rightWrist, _notProvided)
        ? this.rightWrist
        : rightWrist as NormalizedPoint?,
    leftHandVisible: leftHandVisible ?? this.leftHandVisible,
    rightHandVisible: rightHandVisible ?? this.rightHandVisible,
    lightingScore: lightingScore ?? this.lightingScore,
    trackingConfidence: trackingConfidence ?? this.trackingConfidence,
    featureVector: featureVector ?? this.featureVector,
    hands: hands ?? this.hands,
    handCoordinateAnalysis:
        handCoordinateAnalysis ?? this.handCoordinateAnalysis,
    faceExpression: identical(faceExpression, _notProvided)
        ? this.faceExpression
        : faceExpression as FaceExpressionFeatures?,
    poseLandmarks: poseLandmarks ?? this.poseLandmarks,
    faceUpperLandmarks: faceUpperLandmarks ?? this.faceUpperLandmarks,
    faceMouthLandmarks: faceMouthLandmarks ?? this.faceMouthLandmarks,
    subjectTracking: identical(subjectTracking, _notProvided)
        ? this.subjectTracking
        : subjectTracking as SubjectTracking?,
    trackingState: identical(trackingState, _notProvided)
        ? this.trackingState
        : trackingState as TrackingStateResult?,
    normalisation: identical(normalisation, _notProvided)
        ? this.normalisation
        : normalisation as NormalisationResult?,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'timestamp': timestamp.toUtc().toIso8601String(),
    'tracking_confidence': trackingConfidence,
    'left_shoulder': leftShoulder?.toJson(),
    'right_shoulder': rightShoulder?.toJson(),
    'hands': hands.map((hand) => hand.toJson()).toList(),
    'hand_coordinate_analysis': handCoordinateAnalysis
        .map((analysis) => analysis.toJson())
        .toList(),
    'face_expression': faceExpression?.toJson(),
    'subject_tracking': subjectTracking?.toJson(),
    'landmark_worlds': <String, dynamic>{
      'left_hand': _handWorld(Handedness.left),
      'right_hand': _handWorld(Handedness.right),
      'pose': <String, dynamic>{
        'landmarks': poseLandmarks
            .map((landmark) => landmark.toJson())
            .toList(),
      },
      'face': <String, dynamic>{
        'upper': faceUpperLandmarks
            .map((landmark) => landmark.toJson())
            .toList(),
        'mouth': faceMouthLandmarks
            .map((landmark) => landmark.toJson())
            .toList(),
        'emotion': faceExpression?.toJson(),
      },
    },
  };

  Map<String, dynamic> _handWorld(Handedness side) {
    TrackedHand? hand;
    for (final candidate in hands) {
      if (candidate.handedness == side) {
        hand = candidate;
        break;
      }
    }
    return <String, dynamic>{
      'handedness': handednessToString(side),
      'confidence': hand?.confidence ?? 0,
      'finger_status': fingerStatusesToJson(hand?.fingerStatus ?? const {}),
      'landmarks':
          hand?.landmarks
              .asMap()
              .entries
              .map(
                (entry) => <String, dynamic>{
                  'index': entry.key,
                  ...entry.value.toJson(),
                },
              )
              .toList() ??
          <dynamic>[],
    };
  }
}

extension on NormalizedPoint {
  Map<String, dynamic> toJson() => <String, dynamic>{
    'x': x,
    'y': y,
    'z': z,
    'visibility': visibility,
  };
}

class AlignmentConfig {
  const AlignmentConfig({
    this.targetCenter = const NormalizedPoint(x: 0.5, y: 0.56),
    this.horizontalTolerance = 0.07,
    this.verticalTolerance = 0.08,
    this.minimumShoulderWidth = 0.18,
    this.maximumShoulderWidth = 0.48,
  });

  final NormalizedPoint targetCenter;
  final double horizontalTolerance;
  final double verticalTolerance;
  final double minimumShoulderWidth;
  final double maximumShoulderWidth;
}

class AlignmentResult {
  const AlignmentResult({
    required this.isAligned,
    required this.message,
    required this.detail,
    this.shoulderWidth = 0,
    this.horizontalError = 0,
    this.verticalError = 0,
  });

  final bool isAligned;
  final String message;
  final String detail;
  final double shoulderWidth;
  final double horizontalError;
  final double verticalError;
}

class AlignmentEvaluator {
  const AlignmentEvaluator({this.config = const AlignmentConfig()});

  final AlignmentConfig config;

  AlignmentResult evaluate(LandmarkFrame frame) {
    final left = frame.leftShoulder;
    final right = frame.rightShoulder;
    if (left == null || right == null || !left.isVisible || !right.isVisible) {
      return const AlignmentResult(
        isAligned: false,
        message: 'Show both shoulders',
        detail: 'Keep your shoulders and upper body visible in the frame.',
      );
    }

    final midpoint = NormalizedPoint(
      x: (left.x + right.x) / 2,
      y: (left.y + right.y) / 2,
    );
    final width = math.sqrt(
      math.pow(right.x - left.x, 2) + math.pow(right.y - left.y, 2),
    );
    final horizontalError = (midpoint.x - config.targetCenter.x).abs();
    final verticalError = (midpoint.y - config.targetCenter.y).abs();

    if (width < config.minimumShoulderWidth) {
      return AlignmentResult(
        isAligned: false,
        message: 'Move closer',
        detail: 'Your shoulders are too far from the camera.',
        shoulderWidth: width,
        horizontalError: horizontalError,
        verticalError: verticalError,
      );
    }
    if (width > config.maximumShoulderWidth) {
      return AlignmentResult(
        isAligned: false,
        message: 'Move back',
        detail: 'Give your hands and shoulders more room in the frame.',
        shoulderWidth: width,
        horizontalError: horizontalError,
        verticalError: verticalError,
      );
    }
    if (horizontalError >= config.horizontalTolerance) {
      final direction = midpoint.x < config.targetCenter.x ? 'right' : 'left';
      return AlignmentResult(
        isAligned: false,
        message: 'Move slightly to the $direction',
        detail: 'Centre your shoulders on the guide line.',
        shoulderWidth: width,
        horizontalError: horizontalError,
        verticalError: verticalError,
      );
    }
    if (verticalError >= config.verticalTolerance) {
      final direction = midpoint.y < config.targetCenter.y ? 'Lower' : 'Raise';
      return AlignmentResult(
        isAligned: false,
        message: '$direction your shoulders into frame',
        detail: 'Match your shoulders to the horizontal guide.',
        shoulderWidth: width,
        horizontalError: horizontalError,
        verticalError: verticalError,
      );
    }
    return AlignmentResult(
      isAligned: true,
      message: 'Position looks good ✓',
      detail: 'You are ready to continue.',
      shoulderWidth: width,
      horizontalError: horizontalError,
      verticalError: verticalError,
    );
  }
}

class TrackingSampleBuffer {
  TrackingSampleBuffer({this.window = const Duration(seconds: 30)});

  final Duration window;
  final List<_ConfidenceSample> _samples = <_ConfidenceSample>[];

  void add(double confidence, [DateTime? now]) {
    final timestamp = now ?? DateTime.now();
    _samples.add(_ConfidenceSample(timestamp, confidence));
    _prune(timestamp);
  }

  double get average => averageAt();

  double averageAt([DateTime? now]) {
    _prune(now ?? DateTime.now());
    if (_samples.isEmpty) return 0;
    return _samples.map((sample) => sample.value).reduce((a, b) => a + b) /
        _samples.length;
  }

  DateTime? get latestTimestamp =>
      _samples.isEmpty ? null : _samples.last.timestamp;

  String get windowLabel {
    final latest = latestTimestamp;
    if (latest == null) return '[last 30 seconds]';
    final age = DateTime.now().difference(latest).inSeconds.clamp(0, 30);
    return '[last 30 seconds · updated ${age}s ago]';
  }

  void _prune(DateTime now) => _samples.removeWhere(
    (sample) => now.difference(sample.timestamp) > window,
  );
}

class _ConfidenceSample {
  const _ConfidenceSample(this.timestamp, this.value);
  final DateTime timestamp;
  final double value;
}

class CustomSign {
  const CustomSign({
    required this.label,
    required this.samples,
    required this.createdAt,
    this.language = 'ASL',
    this.vectorSize = 0,
    this.coordinateSpace = 'normalized_3d',
    this.faceSignal = 'not captured',
  });

  final String label;
  final List<List<double>> samples;
  final DateTime createdAt;
  final String language;
  final int vectorSize;
  final String coordinateSpace;
  final String faceSignal;

  bool get hasEnoughSamples => samples.length >= 5;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'label': label,
    'samples': samples,
    'createdAt': createdAt.toIso8601String(),
    'language': language,
    'vector_size': vectorSize,
    'coordinate_space': coordinateSpace,
    'face_signal': faceSignal,
  };

  factory CustomSign.fromJson(Map<String, dynamic> json) => CustomSign(
    label: json['label'] as String,
    samples: (json['samples'] as List<dynamic>)
        .map(
          (sample) => (sample as List<dynamic>)
              .map((value) => (value as num).toDouble())
              .toList(),
        )
        .toList(),
    createdAt: DateTime.parse(json['createdAt'] as String),
    language: json['language'] as String? ?? 'ASL',
    vectorSize: (json['vector_size'] as num?)?.toInt() ?? 0,
    coordinateSpace: json['coordinate_space'] as String? ?? 'normalized_3d',
    faceSignal: json['face_signal'] as String? ?? 'not captured',
  );
}
