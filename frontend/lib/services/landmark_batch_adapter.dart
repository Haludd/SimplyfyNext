import '../contracts/landmark_stream.dart';
import '../models/face_tracking_models.dart';
import '../models/hand_tracking_models.dart';
import '../models/tracking_models.dart';

/// Converts the app's rich four-world [LandmarkFrame] into the backend's
/// fixed landmark-stream layout. The server owns normalisation, segmentation,
/// and classification; this adapter only preserves coordinates and quality.
final class LandmarkBatchEncoder {
  LandmarkBatchEncoder({
    required this.camera,
    this.subjectId = 'subject-0',
  }) {
    if (camera.sourceWidth < 1 || camera.sourceHeight < 1) {
      throw ArgumentError('camera dimensions must be positive');
    }
    if (!<int>[0, 90, 180, 270].contains(camera.rotationDegrees)) {
      throw ArgumentError('camera rotation must be 0, 90, 180, or 270');
    }
    if (subjectId.trim().isEmpty) throw ArgumentError('subjectId is required');
  }

  static const List<int> _poseIndices = <int>[0, 11, 12, 13, 14, 15, 16, 23, 24];
  static const List<int> _faceIndices = <int>[
    1,
    152,
    70,
    105,
    107,
    336,
    334,
    300,
    159,
    145,
    386,
    374,
    61,
    13,
    14,
    291,
  ];

  final LandmarkCameraGeometry camera;
  final String subjectId;
  int _batchSeq = 0;
  int _frameSeq = 0;
  int _lastCaptureMs = -1;
  DateTime? _firstTimestamp;

  int get nextBatchSeq => _batchSeq;
  int get nextFrameSeq => _frameSeq;

  LandmarkBatch buildBatch(
    String sessionId,
    List<LandmarkFrame> frames, {
    int droppedBefore = 0,
  }) {
    if (frames.isEmpty) throw ArgumentError('frames must not be empty');
    if (frames.length > 32) {
      throw ArgumentError('frames cannot contain more than 32 items');
    }
    final encoded = frames.map(_encodeFrame).toList(growable: false);
    return LandmarkBatch(
      sessionId: sessionId,
      batchSeq: _batchSeq++,
      camera: camera,
      frames: encoded,
      droppedBefore: droppedBefore,
    );
  }

  Map<String, dynamic> _encodeFrame(LandmarkFrame frame) {
    final captureMs = _captureMs(frame.timestamp);
    final lockedSubject = frame.subjectTracking?.locked == true;
    final hasSubjectPoints = frame.hands.isNotEmpty || frame.poseLandmarks.isNotEmpty;
    return <String, dynamic>{
      'seq': _frameSeq++,
      'capture_ms': captureMs,
      if (lockedSubject || hasSubjectPoints) 'subject_id': subjectId,
      'pose': _pose(frame.poseLandmarks),
      'left_hand': _hand(frame.hands, Handedness.left),
      'right_hand': _hand(frame.hands, Handedness.right),
      'face': _face(frame.faceUpperLandmarks, frame.faceMouthLandmarks),
      'left_hand_score': _handScore(frame.hands, Handedness.left),
      'right_hand_score': _handScore(frame.hands, Handedness.right),
      'tracking_confidence': _confidence(frame.trackingConfidence),
    };
  }

  int _captureMs(DateTime timestamp) {
    final first = _firstTimestamp ??= timestamp;
    final elapsed = timestamp.difference(first).inMilliseconds;
    final next = elapsed > _lastCaptureMs ? elapsed : _lastCaptureMs + 1;
    _lastCaptureMs = next;
    return next;
  }

  List<List<double>> _pose(List<PoseLandmark> landmarks) {
    return _poseIndices
        .map((index) => _pointFromPose(_findPose(landmarks, index)))
        .toList(growable: false);
  }

  List<double> _pointFromPose(PoseLandmark? point) => point == null
      ? <double>[0, 0, 0, 0]
      : <double>[
          _coordinate(point.x),
          _coordinate(point.y),
          _depth(point.z),
          _confidence(point.visibility),
        ];

  List<List<double>>? _hand(List<TrackedHand> hands, Handedness side) {
    final hand = _findHand(hands, side);
    if (hand == null || hand.landmarks.length < 21) return null;
    return List<List<double>>.generate(
      21,
      (index) {
        final point = hand.landmarks[index];
        return <double>[
          _coordinate(point.x),
          _coordinate(point.y),
          _depth(point.z),
          _confidence(point.visibility),
        ];
      },
      growable: false,
    );
  }

  List<List<double>> _face(
    List<FaceLandmark> upper,
    List<FaceLandmark> mouth,
  ) {
    final byIndex = <int, FaceLandmark>{
      for (final point in <FaceLandmark>[...upper, ...mouth])
        point.index: point,
    };
    return _faceIndices
        .map((index) {
          final point = byIndex[index];
          return point == null
              ? <double>[0, 0, 0, 0]
              : <double>[
                  _coordinate(point.x),
                  _coordinate(point.y),
                  _depth(point.z),
                  _confidence(point.visibility),
                ];
        })
        .toList(growable: false);
  }

  double? _handScore(List<TrackedHand> hands, Handedness side) {
    final hand = _findHand(hands, side);
    return hand == null ? null : _confidence(hand.confidence);
  }

  static PoseLandmark? _findPose(List<PoseLandmark> points, int index) {
    for (final point in points) {
      if (point.index == index) return point;
    }
    return null;
  }

  static TrackedHand? _findHand(List<TrackedHand> hands, Handedness side) {
    for (final hand in hands) {
      if (hand.handedness == side) return hand;
    }
    return null;
  }

  static double _coordinate(double value) => _finite(value).clamp(-4.0, 4.0);

  static double _depth(double value) => _finite(value).clamp(-10.0, 10.0);

  static double _confidence(double value) => _finite(value).clamp(0.0, 1.0);

  static double _finite(double value) => value.isFinite ? value : 0.0;
}
