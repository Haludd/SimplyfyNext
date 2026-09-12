import 'dart:math' as math;

import 'face_tracking_models.dart';

const handLandmarkEdges = <List<int>>[
  <int>[0, 1],
  <int>[1, 2],
  <int>[2, 3],
  <int>[3, 4],
  <int>[0, 5],
  <int>[5, 6],
  <int>[6, 7],
  <int>[7, 8],
  <int>[5, 9],
  <int>[9, 10],
  <int>[10, 11],
  <int>[11, 12],
  <int>[9, 13],
  <int>[13, 14],
  <int>[14, 15],
  <int>[15, 16],
  <int>[13, 17],
  <int>[17, 18],
  <int>[18, 19],
  <int>[19, 20],
  <int>[0, 17],
];

enum Handedness { left, right, unknown }

Handedness handednessFromString(String? value) {
  switch (value?.toLowerCase()) {
    case 'left':
      return Handedness.left;
    case 'right':
      return Handedness.right;
    default:
      return Handedness.unknown;
  }
}

String handednessToString(Handedness value) => switch (value) {
  Handedness.left => 'left',
  Handedness.right => 'right',
  Handedness.unknown => 'unknown',
};

/// Quality of the landmarks for one named finger.
///
/// This describes what the tracker can currently see. It is deliberately not
/// called "missing": a hidden finger and an anatomically absent finger can
/// look identical in a camera frame.
class FingerTrackingStatus {
  const FingerTrackingStatus({
    required this.status,
    required this.confidence,
    this.evidenceFrames = 0,
  });

  final String status;
  final double confidence;
  final int evidenceFrames;

  bool get isObserved => status == 'observed';

  String get displayLabel => switch (status) {
    'observed' => 'seen',
    'uncertain' => 'uncertain',
    'not_visible' => 'not visible',
    _ => status,
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'status': status,
    'confidence': confidence,
    'evidence_frames': evidenceFrames,
  };

  factory FingerTrackingStatus.fromJson(Map<String, dynamic> json) =>
      FingerTrackingStatus(
        status: json['status'] as String? ?? 'not_visible',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        evidenceFrames: (json['evidence_frames'] as num?)?.toInt() ?? 0,
      );
}

Map<String, FingerTrackingStatus> _fingerStatusesFromJson(Object? value) {
  if (value is! Map) return const <String, FingerTrackingStatus>{};
  final statuses = <String, FingerTrackingStatus>{};
  value.forEach((key, nestedValue) {
    if (nestedValue is Map) {
      statuses[key.toString()] = FingerTrackingStatus.fromJson(
        Map<String, dynamic>.from(nestedValue),
      );
    }
  });
  return statuses;
}

Map<String, dynamic> fingerStatusesToJson(
  Map<String, FingerTrackingStatus> statuses,
) => <String, dynamic>{
  for (final entry in statuses.entries) entry.key: entry.value.toJson(),
};

class HandLandmark {
  const HandLandmark({
    required this.x,
    required this.y,
    required this.z,
    this.worldX,
    this.worldY,
    this.worldZ,
    this.visibility = 1,
  });

  final double x;
  final double y;
  final double z;
  final double? worldX;
  final double? worldY;
  final double? worldZ;
  final double visibility;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'x': x,
    'y': y,
    'z': z,
    if (worldX != null) 'world_x': worldX,
    if (worldY != null) 'world_y': worldY,
    if (worldZ != null) 'world_z': worldZ,
    'visibility': visibility,
  };

  factory HandLandmark.fromJson(Map<String, dynamic> json) => HandLandmark(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    z: (json['z'] as num?)?.toDouble() ?? 0,
    worldX: (json['world_x'] as num?)?.toDouble(),
    worldY: (json['world_y'] as num?)?.toDouble(),
    worldZ: (json['world_z'] as num?)?.toDouble(),
    visibility: (json['visibility'] as num?)?.toDouble() ?? 1,
  );
}

class TrackedHand {
  const TrackedHand({
    required this.handedness,
    required this.confidence,
    required this.landmarks,
    this.boundingBox = const <double>[],
    this.fingerStatus = const <String, FingerTrackingStatus>{},
  });

  final Handedness handedness;
  final double confidence;
  final List<HandLandmark> landmarks;
  final List<double> boundingBox;
  final Map<String, FingerTrackingStatus> fingerStatus;

  HandLandmark? get wrist => landmarks.isEmpty ? null : landmarks.first;

  double get openness {
    if (landmarks.length < 21) return 0;
    final wrist = landmarks[0];
    final tips = <int>[4, 8, 12, 16, 20];
    final mcps = <int>[2, 5, 9, 13, 17];
    final extended = <bool>[];
    for (var index = 0; index < tips.length; index += 1) {
      final tip = landmarks[tips[index]];
      final mcp = landmarks[mcps[index]];
      final tipDistance = _distance(tip, wrist);
      final mcpDistance = _distance(mcp, wrist);
      extended.add(tipDistance > mcpDistance * 1.18);
    }
    return extended.where((value) => value).length / extended.length;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'handedness': handednessToString(handedness),
    'confidence': confidence,
    'bounding_box': boundingBox,
    'landmarks': landmarks.map((landmark) => landmark.toJson()).toList(),
    'finger_status': fingerStatusesToJson(fingerStatus),
  };

  factory TrackedHand.fromJson(Map<String, dynamic> json) => TrackedHand(
    handedness: handednessFromString(json['handedness'] as String?),
    confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
    boundingBox: (json['bounding_box'] as List<dynamic>? ?? <dynamic>[])
        .map((value) => (value as num).toDouble())
        .toList(),
    landmarks: (json['landmarks'] as List<dynamic>? ?? <dynamic>[])
        .map((value) => HandLandmark.fromJson(value as Map<String, dynamic>))
        .toList(),
    fingerStatus: _fingerStatusesFromJson(json['finger_status']),
  );
}

/// One of the curated MediaPipe Pose points sent across the app boundary.
/// MediaPipe detects all 33 pose points, but the contract keeps the useful
/// upper-body subset small and predictable.
class PoseLandmark {
  const PoseLandmark({
    required this.index,
    required this.name,
    required this.x,
    required this.y,
    required this.z,
    this.visibility = 1,
    this.presence,
  });

  final int index;
  final String name;
  final double x;
  final double y;
  final double z;
  final double visibility;
  final double? presence;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'index': index,
    'name': name,
    'x': x,
    'y': y,
    'z': z,
    'visibility': visibility,
    if (presence != null) 'presence': presence,
  };

  factory PoseLandmark.fromJson(Map<String, dynamic> json) => PoseLandmark(
    index: (json['index'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? 'pose_${json['index'] ?? 0}',
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    z: (json['z'] as num?)?.toDouble() ?? 0,
    visibility: (json['visibility'] as num?)?.toDouble() ?? 1,
    presence: (json['presence'] as num?)?.toDouble(),
  );
}

class SubjectTracking {
  const SubjectTracking({
    required this.locked,
    this.visible = true,
    this.centerX,
    this.centerY,
    this.area = 0,
    this.missingFrames = 0,
  });

  final bool locked;
  final bool visible;
  final double? centerX;
  final double? centerY;
  final double area;
  final int missingFrames;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'locked': locked,
    'visible': visible,
    if (centerX != null) 'center_x': centerX,
    if (centerY != null) 'center_y': centerY,
    'area': area,
    'missing_frames': missingFrames,
  };

  factory SubjectTracking.fromJson(Map<String, dynamic> json) =>
      SubjectTracking(
        locked: json['locked'] as bool? ?? false,
        visible: json['visible'] as bool? ?? true,
        centerX: (json['center_x'] as num?)?.toDouble(),
        centerY: (json['center_y'] as num?)?.toDouble(),
        area: (json['area'] as num?)?.toDouble() ?? 0,
        missingFrames: (json['missing_frames'] as num?)?.toInt() ?? 0,
      );
}

class HandTrackingFrame {
  const HandTrackingFrame({
    required this.timestamp,
    required this.hands,
    this.face,
    this.leftShoulder,
    this.rightShoulder,
    this.poseLandmarks = const <PoseLandmark>[],
    this.faceUpperLandmarks = const <FaceLandmark>[],
    this.faceMouthLandmarks = const <FaceLandmark>[],
    this.subjectTracking,
    this.processingConfidence = 0,
  });

  final DateTime timestamp;
  final List<TrackedHand> hands;
  final FaceExpressionFeatures? face;
  final HandLandmark? leftShoulder;
  final HandLandmark? rightShoulder;
  final List<PoseLandmark> poseLandmarks;
  final List<FaceLandmark> faceUpperLandmarks;
  final List<FaceLandmark> faceMouthLandmarks;
  final SubjectTracking? subjectTracking;
  final double processingConfidence;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'timestamp': timestamp.toUtc().toIso8601String(),
    'processing_confidence': processingConfidence,
    'hands': hands.map((hand) => hand.toJson()).toList(),
    'face': face?.toJson(),
    'left_shoulder': leftShoulder?.toJson(),
    'right_shoulder': rightShoulder?.toJson(),
    'subject_tracking': subjectTracking?.toJson(),
    'landmark_worlds': _landmarkWorldsJson(
      hands: hands,
      poseLandmarks: poseLandmarks,
      faceUpperLandmarks: faceUpperLandmarks,
      faceMouthLandmarks: faceMouthLandmarks,
      face: face,
    ),
  };

  factory HandTrackingFrame.fromJson(Map<String, dynamic> json) {
    final worlds = _parseLandmarkWorlds(json['landmark_worlds']);
    final rawHands = (json['hands'] as List<dynamic>? ?? <dynamic>[])
        .map((value) => TrackedHand.fromJson(value as Map<String, dynamic>))
        .toList();
    final timestamp = json['timestamp_ms'] as num?;
    final timestampText = json['timestamp'] as String?;
    return HandTrackingFrame(
      timestamp: timestamp != null
          ? DateTime.fromMillisecondsSinceEpoch(timestamp.toInt())
          : timestampText != null
          ? DateTime.tryParse(timestampText) ?? DateTime.now()
          : DateTime.now(),
      processingConfidence:
          (json['processing_confidence'] as num?)?.toDouble() ?? 0,
      face: _faceFromJson(json['face']) ?? worlds.face,
      leftShoulder: _landmarkFromJson(json['left_shoulder']),
      rightShoulder: _landmarkFromJson(json['right_shoulder']),
      poseLandmarks: worlds.pose,
      faceUpperLandmarks: worlds.faceUpper,
      faceMouthLandmarks: worlds.faceMouth,
      subjectTracking: _subjectFromJson(json['subject_tracking']),
      hands: rawHands.isNotEmpty ? rawHands : worlds.hands,
    );
  }
}

HandLandmark? _landmarkFromJson(Object? value) =>
    value is Map<String, dynamic> ? HandLandmark.fromJson(value) : null;

FaceExpressionFeatures? _faceFromJson(Object? value) =>
    value is Map<String, dynamic>
    ? FaceExpressionFeatures.fromJson(value)
    : null;

SubjectTracking? _subjectFromJson(Object? value) =>
    value is Map<String, dynamic> ? SubjectTracking.fromJson(value) : null;

Map<String, dynamic>? _stringKeyedMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, nestedValue) => MapEntry(key.toString(), nestedValue));
}

class _LandmarkWorlds {
  const _LandmarkWorlds({
    this.hands = const <TrackedHand>[],
    this.pose = const <PoseLandmark>[],
    this.faceUpper = const <FaceLandmark>[],
    this.faceMouth = const <FaceLandmark>[],
    this.face,
  });

  final List<TrackedHand> hands;
  final List<PoseLandmark> pose;
  final List<FaceLandmark> faceUpper;
  final List<FaceLandmark> faceMouth;
  final FaceExpressionFeatures? face;
}

_LandmarkWorlds _parseLandmarkWorlds(Object? value) {
  final worlds = _stringKeyedMap(value);
  if (worlds == null) return const _LandmarkWorlds();

  final hands = <TrackedHand>[];
  for (final side in <String>['left', 'right']) {
    final world = _stringKeyedMap(worlds['${side}_hand']);
    if (world == null) continue;
    final landmarks = (world['landmarks'] as List<dynamic>? ?? <dynamic>[])
        .map((point) => HandLandmark.fromJson(_stringKeyedMap(point)!))
        .toList();
    if (landmarks.isNotEmpty) {
      hands.add(
        TrackedHand(
          handedness: handednessFromString(side),
          confidence: (world['confidence'] as num?)?.toDouble() ?? 0,
          landmarks: landmarks,
          fingerStatus: _fingerStatusesFromJson(world['finger_status']),
        ),
      );
    }
  }

  final poseWorld = _stringKeyedMap(worlds['pose']);
  final faceWorld = _stringKeyedMap(worlds['face']);
  return _LandmarkWorlds(
    hands: hands,
    pose: (poseWorld?['landmarks'] as List<dynamic>? ?? <dynamic>[])
        .map((point) => PoseLandmark.fromJson(_stringKeyedMap(point)!))
        .toList(growable: false),
    faceUpper: (faceWorld?['upper'] as List<dynamic>? ?? <dynamic>[])
        .map((point) => FaceLandmark.fromJson(_stringKeyedMap(point)!))
        .toList(growable: false),
    faceMouth: (faceWorld?['mouth'] as List<dynamic>? ?? <dynamic>[])
        .map((point) => FaceLandmark.fromJson(_stringKeyedMap(point)!))
        .toList(growable: false),
    face: _faceFromJson(faceWorld?['emotion']),
  );
}

Map<String, dynamic> _landmarkWorldsJson({
  required List<TrackedHand> hands,
  required List<PoseLandmark> poseLandmarks,
  required List<FaceLandmark> faceUpperLandmarks,
  required List<FaceLandmark> faceMouthLandmarks,
  required FaceExpressionFeatures? face,
}) {
  TrackedHand? handFor(Handedness side) {
    for (final hand in hands) {
      if (hand.handedness == side) return hand;
    }
    return null;
  }

  Map<String, dynamic> handWorld(Handedness side) {
    final hand = handFor(side);
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

  return <String, dynamic>{
    'left_hand': handWorld(Handedness.left),
    'right_hand': handWorld(Handedness.right),
    'pose': <String, dynamic>{
      'landmarks': poseLandmarks.map((landmark) => landmark.toJson()).toList(),
    },
    'face': <String, dynamic>{
      'upper': faceUpperLandmarks.map((landmark) => landmark.toJson()).toList(),
      'mouth': faceMouthLandmarks.map((landmark) => landmark.toJson()).toList(),
      'emotion': face?.toJson(),
    },
  };
}

double _distance(HandLandmark a, HandLandmark b) =>
    math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
