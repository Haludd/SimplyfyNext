import 'dart:math' as math;

import 'package:apptesting/models/face_tracking_models.dart';
import 'package:apptesting/models/hand_coordinate_analysis.dart';
import 'package:apptesting/models/hand_tracking_models.dart';
import 'package:apptesting/models/tracking_models.dart';

/// Deterministic Stage 1/2 outputs at Harold's `LandmarkFrame` boundary.
///
/// These fixtures model the Dart object emitted by `WebTrackingService` after
/// `HandPoseNormalizer`. They do not call MediaPipe and they do not pre-fill
/// Stage 3 tracking-state or Stage 4 normalisation results.
///
/// Canonical absence rules used here:
/// - a missing hand is omitted from [LandmarkFrame.hands];
/// - a missing pose or face point is omitted from its sparse indexed list;
/// - a missing point inside an otherwise detected 21-point hand remains a
///   positional [HandLandmark] with zero x/y/z and zero visibility.
abstract final class LandmarkFrameFixtures {
  static final DateTime epoch = DateTime.utc(2026, 9, 6, 12);
  static const Duration frameInterval = Duration(microseconds: 33333);
  static const Object _notProvided = Object();

  /// Complete Stage 1/2 output: locked subject, two 21-point hands, the
  /// curated pose/face subsets, high visibility, handedness confidence,
  /// finger status, shoulders, timestamps, and frame tracking confidence.
  static LandmarkFrame fullyTrackedFrame({DateTime? timestamp}) =>
      haroldFrame(timestamp: timestamp);

  /// No subject and no observed landmark group. No coordinate is fabricated.
  static LandmarkFrame noSubjectFrame({DateTime? timestamp}) => haroldFrame(
    timestamp: timestamp ?? atFrame(1),
    trackingConfidence: 0,
    hands: const <TrackedHand>[],
    poseLandmarks: const <PoseLandmark>[],
    faceUpperLandmarks: const <FaceLandmark>[],
    faceMouthLandmarks: const <FaceLandmark>[],
    faceExpression: null,
    subjectTracking: const SubjectTracking(
      locked: false,
      // Harold's JavaScript omits `visible` before a subject is locked, and
      // the canonical Dart parser therefore applies its `true` default.
      visible: true,
      area: 0,
      missingFrames: 0,
    ),
    featureVector: List<double>.filled(322, 0),
  );

  /// The right shoulder is absent from both the top-level shortcut and the
  /// sparse pose list. Hands and the remaining observations stay valid.
  static LandmarkFrame oneShoulderMissingFrame({DateTime? timestamp}) =>
      haroldFrame(
        timestamp: timestamp,
        poseLandmarks: realisticPose(missingIndices: const <int>{12}),
      );

  /// Both shoulders exist but are less than 0.0001 image units apart.
  static LandmarkFrame tinyShoulderScaleFrame({DateTime? timestamp}) =>
      haroldFrame(
        timestamp: timestamp,
        poseLandmarks: realisticPose(
          coordinateOverrides: const <int, NormalizedPoint>{
            11: NormalizedPoint(x: 0.5, y: 0.35, z: -0.05),
            12: NormalizedPoint(x: 0.500099, y: 0.35, z: -0.05),
          },
        ),
      );

  /// Shoulder separation is exactly the implementation's 0.0001 boundary.
  static LandmarkFrame minimumShoulderScaleFrame({DateTime? timestamp}) =>
      haroldFrame(
        timestamp: timestamp,
        poseLandmarks: realisticPose(
          coordinateOverrides: const <int, NormalizedPoint>{
            11: NormalizedPoint(x: 0, y: 0.35, z: -0.05),
            12: NormalizedPoint(x: 0.0001, y: 0.35, z: -0.05),
          },
        ),
      );

  /// Shoulders span almost the full image width, exercising a large scale.
  static LandmarkFrame largeShoulderScaleFrame({DateTime? timestamp}) =>
      haroldFrame(
        timestamp: timestamp,
        poseLandmarks: realisticPose(
          coordinateOverrides: const <int, NormalizedPoint>{
            11: NormalizedPoint(x: 0.01, y: 0.35, z: -0.05),
            12: NormalizedPoint(x: 0.99, y: 0.35, z: -0.05),
          },
        ),
      );

  /// All landmark visibility values are below the Stage 3 confidence gate.
  /// Hand `confidence` intentionally remains high because it is handedness
  /// confidence, not per-point tracking confidence.
  static LandmarkFrame lowConfidenceFrame({DateTime? timestamp}) => haroldFrame(
    timestamp: timestamp,
    trackingConfidence: 0.1,
    poseLandmarks: realisticPose(visibility: 0.1),
    faceUpperLandmarks: realisticFaceUpper(visibility: 0.1),
    faceMouthLandmarks: realisticFaceMouth(visibility: 0.1),
    faceExpression: realisticFaceExpression(confidence: 0.1),
    hands: <TrackedHand>[
      realisticHand(handedness: Handedness.left, pointVisibility: 0.1),
      realisticHand(handedness: Handedness.right, pointVisibility: 0.1),
    ],
  );

  /// Shoulders and hand points 0..10 are strong; the remaining pose and hand
  /// points have extremely low visibility.
  static LandmarkFrame mixedConfidenceFrame({DateTime? timestamp}) {
    final poseVisibility = <int, double>{
      for (final index in poseIndices) index: 0.01,
      11: 0.98,
      12: 0.98,
    };
    final handVisibility = <int, double>{
      for (var index = 0; index < 21; index += 1)
        index: index <= 10 ? 0.96 : 0.01,
    };
    return haroldFrame(
      timestamp: timestamp,
      trackingConfidence: 0.52,
      poseLandmarks: realisticPose(visibilityOverrides: poseVisibility),
      hands: <TrackedHand>[
        realisticHand(
          handedness: Handedness.right,
          visibilityOverrides: handVisibility,
        ),
      ],
    );
  }

  /// Valid pose/face observations with Harold's normal empty hand list.
  static LandmarkFrame missingHandsFrame({DateTime? timestamp}) => haroldFrame(
    timestamp: timestamp,
    trackingConfidence: 0.84,
    hands: const <TrackedHand>[],
  );

  /// Two valid hands remain while pose and top-level shoulders are absent.
  static LandmarkFrame handsWithoutPoseFrame({DateTime? timestamp}) =>
      haroldFrame(
        timestamp: timestamp,
        trackingConfidence: 0.9,
        poseLandmarks: const <PoseLandmark>[],
      );

  /// Compatibility name for tests describing the same hands-without-pose
  /// condition.
  static LandmarkFrame missingPoseFrame({DateTime? timestamp}) =>
      handsWithoutPoseFrame(timestamp: timestamp);

  /// One 30 FPS frame after [fullyTrackedFrame], with the entire right hand
  /// abruptly translated from a wrist x of 0.70 to 0.05.
  static LandmarkFrame discontinuityFrame({DateTime? timestamp}) => haroldFrame(
    timestamp: timestamp ?? atFrame(1),
    hands: <TrackedHand>[
      realisticHand(handedness: Handedness.left),
      realisticHand(handedness: Handedness.right, wristX: 0.05),
    ],
  );

  /// A changed observation with the same timestamp as [fullyTrackedFrame].
  /// It gives Stage 4 an explicit zero-delta temporal case.
  static LandmarkFrame invalidTimestampFrame({DateTime? timestamp}) =>
      haroldFrame(
        timestamp: timestamp ?? epoch,
        hands: <TrackedHand>[
          realisticHand(handedness: Handedness.left),
          realisticHand(handedness: Handedness.right, wristX: 0.72),
        ],
      );

  /// A valid frame after a run of missing frames. The input contract has no
  /// frame index or subject ID; recovery continuity comes from timestamp and
  /// [SubjectTracking].
  static LandmarkFrame recoveryFrame({DateTime? timestamp}) =>
      fullyTrackedFrame(timestamp: timestamp ?? atFrame(4));

  /// Every point uses the same visibility value. Handedness confidence stays
  /// separate and high.
  static LandmarkFrame confidenceBoundaryFrame(
    double visibility, {
    DateTime? timestamp,
  }) => haroldFrame(
    timestamp: timestamp,
    trackingConfidence: visibility,
    poseLandmarks: realisticPose(visibility: visibility),
    faceUpperLandmarks: realisticFaceUpper(visibility: visibility),
    faceMouthLandmarks: realisticFaceMouth(visibility: visibility),
    hands: <TrackedHand>[
      realisticHand(handedness: Handedness.left, pointVisibility: visibility),
      realisticHand(handedness: Handedness.right, pointVisibility: visibility),
    ],
  );

  /// Right index tip 8 is a Stage 1/2 positional missing-point placeholder:
  /// it is non-null, but has zero x/y/z and zero visibility.
  static LandmarkFrame missingLandmarkFrame({DateTime? timestamp}) =>
      haroldFrame(
        timestamp: timestamp ?? atFrame(1),
        hands: <TrackedHand>[
          realisticHand(handedness: Handedness.left),
          realisticHand(
            handedness: Handedness.right,
            missingIndices: const <int>{8},
          ),
        ],
      );

  static LandmarkFrame reappearingLandmarkFrame({DateTime? timestamp}) =>
      fullyTrackedFrame(timestamp: timestamp ?? atFrame(2));

  /// Valid observations on the normalized image boundaries. In particular,
  /// (0,0) has positive visibility and therefore is not a missing point.
  static LandmarkFrame coordinateExtremesFrame({DateTime? timestamp}) =>
      haroldFrame(
        timestamp: timestamp,
        poseLandmarks: realisticPose(
          coordinateOverrides: const <int, NormalizedPoint>{
            11: NormalizedPoint(x: 0, y: 0.5, z: -0.05),
            12: NormalizedPoint(x: 1, y: 0.5, z: -0.05),
          },
        ),
        hands: <TrackedHand>[
          realisticHand(
            handedness: Handedness.right,
            coordinateOverrides: const <int, NormalizedPoint>{
              0: NormalizedPoint(x: 0, y: 0, z: -0.01),
              8: NormalizedPoint(x: 1, y: 1, z: -0.02),
            },
          ),
        ],
      );

  /// Harold reports an unknown raw handedness label and neutral confidence.
  static LandmarkFrame ambiguousHandednessFrame({
    DateTime? timestamp,
    double handednessConfidence = 0.5,
  }) => haroldFrame(
    timestamp: timestamp,
    hands: <TrackedHand>[
      realisticHand(
        handedness: Handedness.unknown,
        handednessConfidence: handednessConfidence,
      ),
    ],
  );

  /// Combines a missing shoulder, low-confidence pose, and a detected hand
  /// whose 21 positions all represent missing measurements.
  static LandmarkFrame completelyUnusableFrame({DateTime? timestamp}) =>
      haroldFrame(
        timestamp: timestamp,
        trackingConfidence: 0.01,
        poseLandmarks: realisticPose(
          visibility: 0.01,
          missingIndices: const <int>{11},
          coordinateOverrides: const <int, NormalizedPoint>{
            12: NormalizedPoint(x: double.nan, y: 0.35, z: -0.05),
          },
        ),
        faceUpperLandmarks: const <FaceLandmark>[],
        faceMouthLandmarks: const <FaceLandmark>[],
        faceExpression: null,
        hands: <TrackedHand>[
          realisticHand(
            handedness: Handedness.unknown,
            handednessConfidence: 0.5,
            missingIndices: allHandIndices,
          ),
        ],
      );

  /// General canonical frame builder. Defaults form [fullyTrackedFrame].
  /// Nullable shortcut fields accept an explicit null via the sentinel-backed
  /// [Object] parameters.
  static LandmarkFrame haroldFrame({
    DateTime? timestamp,
    double trackingConfidence = 0.97,
    List<TrackedHand>? hands,
    List<PoseLandmark>? poseLandmarks,
    List<FaceLandmark>? faceUpperLandmarks,
    List<FaceLandmark>? faceMouthLandmarks,
    Object? leftShoulder = _notProvided,
    Object? rightShoulder = _notProvided,
    Object? leftWrist = _notProvided,
    Object? rightWrist = _notProvided,
    bool? leftHandVisible,
    bool? rightHandVisible,
    double lightingScore = 0.9,
    List<double>? featureVector,
    List<HandCoordinateAnalysis>? handCoordinateAnalysis,
    Object? faceExpression = _notProvided,
    Object? subjectTracking = _notProvided,
  }) {
    final resolvedHands =
        hands ??
        <TrackedHand>[
          realisticHand(handedness: Handedness.left),
          realisticHand(handedness: Handedness.right),
        ];
    final resolvedPose = poseLandmarks ?? realisticPose();
    final resolvedUpper = faceUpperLandmarks ?? realisticFaceUpper();
    final resolvedMouth = faceMouthLandmarks ?? realisticFaceMouth();
    final resolvedFaceExpression = identical(faceExpression, _notProvided)
        ? realisticFaceExpression()
        : faceExpression as FaceExpressionFeatures?;
    final leftHand = _handFor(resolvedHands, Handedness.left);
    final rightHand = _handFor(resolvedHands, Handedness.right);

    return LandmarkFrame(
      timestamp: timestamp ?? epoch,
      leftShoulder: identical(leftShoulder, _notProvided)
          ? _shoulderFromPose(resolvedPose, 11)
          : leftShoulder as NormalizedPoint?,
      rightShoulder: identical(rightShoulder, _notProvided)
          ? _shoulderFromPose(resolvedPose, 12)
          : rightShoulder as NormalizedPoint?,
      leftWrist: identical(leftWrist, _notProvided)
          ? _wristFromHand(leftHand)
          : leftWrist as NormalizedPoint?,
      rightWrist: identical(rightWrist, _notProvided)
          ? _wristFromHand(rightHand)
          : rightWrist as NormalizedPoint?,
      leftHandVisible: leftHandVisible ?? leftHand != null,
      rightHandVisible: rightHandVisible ?? rightHand != null,
      lightingScore: lightingScore,
      trackingConfidence: trackingConfidence,
      featureVector:
          featureVector ??
          realisticFeatureVector(
            hands: resolvedHands,
            poseLandmarks: resolvedPose,
            faceUpperLandmarks: resolvedUpper,
            faceMouthLandmarks: resolvedMouth,
            faceExpression: resolvedFaceExpression,
          ),
      hands: resolvedHands,
      handCoordinateAnalysis:
          handCoordinateAnalysis ??
          const HandCoordinateAnalyzer().analyze(resolvedHands),
      faceExpression: resolvedFaceExpression,
      poseLandmarks: resolvedPose,
      faceUpperLandmarks: resolvedUpper,
      faceMouthLandmarks: resolvedMouth,
      subjectTracking: identical(subjectTracking, _notProvided)
          ? const SubjectTracking(
              locked: true,
              visible: true,
              centerX: 0.5,
              centerY: 0.42,
              area: 0.22,
              missingFrames: 0,
            )
          : subjectTracking as SubjectTracking?,
    );
  }

  /// Copy-style raw-frame builder preserving every canonical Stage 1/2 field
  /// unless the caller replaces it. Empty lists clear list fields; explicit
  /// null clears nullable fields.
  static LandmarkFrame copyFrame(
    LandmarkFrame source, {
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
  }) => LandmarkFrame(
    timestamp: timestamp ?? source.timestamp,
    leftShoulder: identical(leftShoulder, _notProvided)
        ? source.leftShoulder
        : leftShoulder as NormalizedPoint?,
    rightShoulder: identical(rightShoulder, _notProvided)
        ? source.rightShoulder
        : rightShoulder as NormalizedPoint?,
    leftWrist: identical(leftWrist, _notProvided)
        ? source.leftWrist
        : leftWrist as NormalizedPoint?,
    rightWrist: identical(rightWrist, _notProvided)
        ? source.rightWrist
        : rightWrist as NormalizedPoint?,
    leftHandVisible: leftHandVisible ?? source.leftHandVisible,
    rightHandVisible: rightHandVisible ?? source.rightHandVisible,
    lightingScore: lightingScore ?? source.lightingScore,
    trackingConfidence: trackingConfidence ?? source.trackingConfidence,
    featureVector: featureVector ?? source.featureVector,
    hands: hands ?? source.hands,
    handCoordinateAnalysis:
        handCoordinateAnalysis ?? source.handCoordinateAnalysis,
    faceExpression: identical(faceExpression, _notProvided)
        ? source.faceExpression
        : faceExpression as FaceExpressionFeatures?,
    poseLandmarks: poseLandmarks ?? source.poseLandmarks,
    faceUpperLandmarks: faceUpperLandmarks ?? source.faceUpperLandmarks,
    faceMouthLandmarks: faceMouthLandmarks ?? source.faceMouthLandmarks,
    subjectTracking: identical(subjectTracking, _notProvided)
        ? source.subjectTracking
        : subjectTracking as SubjectTracking?,
  );

  /// Harold retains only the agreed 11 pose points, each carrying its actual
  /// MediaPipe index. Missing points are omitted rather than represented by a
  /// null slot.
  static List<PoseLandmark> realisticPose({
    double visibility = 0.98,
    Set<int> missingIndices = const <int>{},
    Map<int, NormalizedPoint> coordinateOverrides =
        const <int, NormalizedPoint>{},
    Map<int, double> visibilityOverrides = const <int, double>{},
    Map<int, double?> presenceOverrides = const <int, double?>{},
  }) => <PoseLandmark>[
    for (final index in poseIndices)
      if (!missingIndices.contains(index))
        PoseLandmark(
          index: index,
          name: poseNames[index]!,
          x: (coordinateOverrides[index] ?? poseCoordinates[index]!).x,
          y: (coordinateOverrides[index] ?? poseCoordinates[index]!).y,
          z: (coordinateOverrides[index] ?? poseCoordinates[index]!).z,
          visibility: visibilityOverrides[index] ?? visibility,
          presence: presenceOverrides.containsKey(index)
              ? presenceOverrides[index]
              : visibilityOverrides[index] ?? visibility,
        ),
  ];

  /// A complete MediaPipe hand: exactly 21 non-null positional points.
  static TrackedHand realisticHand({
    required Handedness handedness,
    double handednessConfidence = 0.95,
    double pointVisibility = 0.96,
    double? wristX,
    double wristY = 0.58,
    Set<int> missingIndices = const <int>{},
    Map<int, NormalizedPoint> coordinateOverrides =
        const <int, NormalizedPoint>{},
    Map<int, NormalizedPoint> worldOverrides = const <int, NormalizedPoint>{},
    Map<int, double> visibilityOverrides = const <int, double>{},
    List<double>? boundingBox,
    Map<String, FingerTrackingStatus>? fingerStatus,
  }) {
    final isLeft = handedness == Handedness.left;
    final templateWristX = isLeft ? 0.30 : 0.70;
    final targetWristX = wristX ?? templateWristX;
    final landmarks = List<HandLandmark>.generate(21, (index) {
      if (missingIndices.contains(index)) {
        return const HandLandmark(x: 0, y: 0, z: 0, visibility: 0);
      }
      final template = leftHandImageCoordinates[index]!;
      final templateX = isLeft ? template.x : 1 - template.x;
      final image =
          coordinateOverrides[index] ??
          NormalizedPoint(
            x: targetWristX + templateX - templateWristX,
            y: wristY + template.y - 0.58,
            z: template.z,
          );
      final templateWorld = rightHandWorldCoordinates[index]!;
      final world =
          worldOverrides[index] ??
          NormalizedPoint(
            x: isLeft ? -templateWorld.x : templateWorld.x,
            y: templateWorld.y,
            z: templateWorld.z,
          );
      return HandLandmark(
        x: image.x,
        y: image.y,
        z: image.z,
        worldX: world.x,
        worldY: world.y,
        worldZ: world.z,
        visibility: visibilityOverrides[index] ?? pointVisibility,
      );
    }, growable: false);

    return TrackedHand(
      handedness: handedness,
      confidence: handednessConfidence,
      landmarks: landmarks,
      // Harold's current JavaScript producer does not emit `bounding_box`,
      // so the canonical parser supplies the model's empty-list default.
      boundingBox: boundingBox ?? const <double>[],
      fingerStatus: fingerStatus ?? realisticFingerStatus,
    );
  }

  /// Sparse upper-face subset with explicit original Face Mesh indices.
  static List<FaceLandmark> realisticFaceUpper({
    double visibility = 0.94,
    Set<int> missingIndices = const <int>{},
    Map<int, double> visibilityOverrides = const <int, double>{},
  }) => <FaceLandmark>[
    for (var position = 0; position < faceUpperIndices.length; position += 1)
      if (!missingIndices.contains(faceUpperIndices[position]))
        FaceLandmark(
          index: faceUpperIndices[position],
          name: faceUpperNames[faceUpperIndices[position]],
          x: 0.43 + (position % 8) * 0.02,
          y: 0.16 + (position ~/ 8) * 0.018,
          z: -0.15 + (position % 3) * 0.002,
          visibility:
              visibilityOverrides[faceUpperIndices[position]] ?? visibility,
        ),
  ];

  /// Sparse mouth subset with explicit original Face Mesh indices.
  static List<FaceLandmark> realisticFaceMouth({
    double visibility = 0.94,
    Set<int> missingIndices = const <int>{},
    Map<int, double> visibilityOverrides = const <int, double>{},
  }) => <FaceLandmark>[
    for (var position = 0; position < faceMouthIndices.length; position += 1)
      if (!missingIndices.contains(faceMouthIndices[position]))
        FaceLandmark(
          index: faceMouthIndices[position],
          name: faceMouthNames[faceMouthIndices[position]],
          x: 0.46 + (position % 6) * 0.016,
          y: 0.225 + (position ~/ 6) * 0.014,
          z: -0.16 + (position % 2) * 0.002,
          visibility:
              visibilityOverrides[faceMouthIndices[position]] ?? visibility,
        ),
  ];

  static FaceExpressionFeatures realisticFaceExpression({
    double confidence = 0.88,
  }) => FaceExpressionFeatures(
    confidence: confidence,
    label: 'neutral',
    source: 'deepface',
    // DeepFace results currently carry emotion scores only. Face geometry is
    // supplied separately in `faceUpperLandmarks`/`faceMouthLandmarks`.
    landmarks: const <FaceLandmark>[],
    emotionScores: const <String, double>{
      'angry': 0.01,
      'disgust': 0.01,
      'fear': 0.01,
      'happy': 0.05,
      'sad': 0.02,
      'surprise': 0.02,
      'neutral': 0.88,
    },
  );

  /// Reproduces Harold's current `HandPoseNormalizer` feature-vector layout
  /// from the same raw fixture values. Stage 3/4 preserve this vector but do
  /// not reinterpret it as their own normalised output.
  static List<double> realisticFeatureVector({
    List<TrackedHand>? hands,
    List<PoseLandmark>? poseLandmarks,
    List<FaceLandmark>? faceUpperLandmarks,
    List<FaceLandmark>? faceMouthLandmarks,
    FaceExpressionFeatures? faceExpression,
  }) {
    final resolvedHands =
        hands ??
        <TrackedHand>[
          realisticHand(handedness: Handedness.left),
          realisticHand(handedness: Handedness.right),
        ];
    final resolvedPose = poseLandmarks ?? realisticPose();
    final resolvedUpper = faceUpperLandmarks ?? realisticFaceUpper();
    final resolvedMouth = faceMouthLandmarks ?? realisticFaceMouth();
    final left = _handFor(resolvedHands, Handedness.left);
    final right = _handFor(resolvedHands, Handedness.right);

    return <double>[
      ..._normalisedHandVector(left),
      ..._normalisedHandVector(right),
      ..._normalisedPoseVector(resolvedPose),
      ..._normalisedFaceVector(resolvedUpper, resolvedMouth),
      _averageOpenness(resolvedHands),
      for (final emotion in deepFaceEmotionLabels)
        faceExpression?.emotionScores[emotion] ?? 0,
    ];
  }

  static DateTime atFrame(int offset) =>
      epoch.add(Duration(microseconds: frameInterval.inMicroseconds * offset));

  static NormalizedPoint? _shoulderFromPose(
    List<PoseLandmark> landmarks,
    int index,
  ) {
    for (final landmark in landmarks) {
      if (landmark.index == index) {
        return NormalizedPoint(
          x: landmark.x,
          y: landmark.y,
          z: landmark.z,
          visibility: landmark.visibility,
        );
      }
    }
    return null;
  }

  static TrackedHand? _handFor(List<TrackedHand> hands, Handedness handedness) {
    for (final hand in hands) {
      if (hand.handedness == handedness) return hand;
    }
    return null;
  }

  /// Mirrors Harold's current convenience-wrist construction: its visibility
  /// is the hand's label confidence. Per-point gating must still use the hand
  /// landmark's own [HandLandmark.visibility].
  static NormalizedPoint? _wristFromHand(TrackedHand? hand) {
    final wrist = hand?.wrist;
    if (wrist == null) return null;
    return NormalizedPoint(
      x: wrist.x,
      y: wrist.y,
      z: wrist.z,
      visibility: hand!.confidence,
    );
  }

  static List<double> _normalisedHandVector(TrackedHand? hand) {
    if (hand == null || hand.landmarks.length < 21) {
      return List<double>.filled(21 * 3, 0);
    }
    final wrist = hand.landmarks.first;
    final middleMcp = hand.landmarks[9];
    final indexMcp = hand.landmarks[5];
    final pinkyMcp = hand.landmarks[17];
    final span =
        ((middleMcp.x - wrist.x).abs() +
            (middleMcp.y - wrist.y).abs() +
            (indexMcp.x - pinkyMcp.x).abs()) /
        3;
    final safeSpan = span.clamp(0.08, 1.0);
    return <double>[
      for (final landmark in hand.landmarks) ...<double>[
        (landmark.x - wrist.x) / safeSpan,
        (landmark.y - wrist.y) / safeSpan,
        (landmark.z - wrist.z) / safeSpan,
      ],
    ];
  }

  static List<double> _normalisedPoseVector(List<PoseLandmark> landmarks) {
    PoseLandmark? byIndex(int index) {
      for (final landmark in landmarks) {
        if (landmark.index == index) return landmark;
      }
      return null;
    }

    final leftShoulder = byIndex(11);
    final rightShoulder = byIndex(12);
    final centerX = leftShoulder != null && rightShoulder != null
        ? (leftShoulder.x + rightShoulder.x) / 2
        : 0.5;
    final centerY = leftShoulder != null && rightShoulder != null
        ? (leftShoulder.y + rightShoulder.y) / 2
        : 0.5;
    final shoulderSpan = leftShoulder != null && rightShoulder != null
        ? math
              .sqrt(
                math.pow(rightShoulder.x - leftShoulder.x, 2) +
                    math.pow(rightShoulder.y - leftShoulder.y, 2),
              )
              .clamp(0.1, 1.0)
        : 1.0;
    return <double>[
      for (final index in poseIndices)
        if (byIndex(index) case final landmark?) ...<double>[
          (landmark.x - centerX) / shoulderSpan,
          (landmark.y - centerY) / shoulderSpan,
          landmark.z / shoulderSpan,
          landmark.visibility,
        ] else ...const <double>[0, 0, 0, 0],
    ];
  }

  static List<double> _normalisedFaceVector(
    List<FaceLandmark> upper,
    List<FaceLandmark> mouth,
  ) {
    final landmarks = <FaceLandmark>[...upper, ...mouth];
    if (landmarks.isEmpty) return List<double>.filled(36 * 4, 0);
    final minX = landmarks.map((point) => point.x).reduce(math.min);
    final maxX = landmarks.map((point) => point.x).reduce(math.max);
    final minY = landmarks.map((point) => point.y).reduce(math.min);
    final maxY = landmarks.map((point) => point.y).reduce(math.max);
    final centerX = (minX + maxX) / 2;
    final centerY = (minY + maxY) / 2;
    final span = math.max(maxX - minX, maxY - minY).clamp(0.08, 1.0);
    final vector = <double>[
      for (final landmark in landmarks) ...<double>[
        (landmark.x - centerX) / span,
        (landmark.y - centerY) / span,
        landmark.z / span,
        landmark.visibility,
      ],
    ];
    if (vector.length < 36 * 4) {
      vector.addAll(List<double>.filled(36 * 4 - vector.length, 0));
    }
    return vector.take(36 * 4).toList(growable: false);
  }

  static double _averageOpenness(List<TrackedHand> hands) => hands.isEmpty
      ? 0
      : hands.map((hand) => hand.openness).reduce((a, b) => a + b) /
            hands.length;

  static const List<int> poseIndices = <int>[
    0,
    11,
    12,
    13,
    14,
    15,
    16,
    23,
    24,
    25,
    26,
  ];

  static const Map<int, String> poseNames = <int, String>{
    0: 'nose',
    11: 'left_shoulder',
    12: 'right_shoulder',
    13: 'left_elbow',
    14: 'right_elbow',
    15: 'left_wrist',
    16: 'right_wrist',
    23: 'left_hip',
    24: 'right_hip',
    25: 'left_knee',
    26: 'right_knee',
  };

  static const Set<int> allHandIndices = <int>{
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
  };

  static const List<int> faceUpperIndices = <int>[
    33,
    133,
    160,
    159,
    158,
    157,
    173,
    362,
    263,
    387,
    386,
    385,
    384,
    398,
    70,
    63,
    105,
    66,
    107,
    336,
    296,
    334,
    293,
    300,
  ];

  static const Map<int, String> faceUpperNames = <int, String>{
    33: 'left_eye_outer',
    133: 'left_eye_inner',
    160: 'left_eye_upper',
    159: 'left_eye_center_upper',
    158: 'left_eye_center_lower',
    157: 'left_eye_lower',
    173: 'left_eye_inner_lower',
    362: 'right_eye_outer',
    263: 'right_eye_inner',
    387: 'right_eye_upper',
    386: 'right_eye_center_upper',
    385: 'right_eye_center_lower',
    384: 'right_eye_lower',
    398: 'right_eye_inner_lower',
    70: 'left_brow_outer',
    63: 'left_brow_inner',
    105: 'left_brow_center',
    66: 'left_brow_upper',
    107: 'left_brow_lower',
    336: 'right_brow_outer',
    296: 'right_brow_inner',
    334: 'right_brow_center',
    293: 'right_brow_upper',
    300: 'right_brow_lower',
  };

  static const List<int> faceMouthIndices = <int>[
    61,
    291,
    0,
    17,
    13,
    14,
    78,
    308,
    82,
    312,
    95,
    324,
  ];

  static const Map<int, String> faceMouthNames = <int, String>{
    61: 'mouth_left',
    291: 'mouth_right',
    0: 'mouth_top_center',
    17: 'mouth_bottom_center',
    13: 'upper_lip_center',
    14: 'lower_lip_center',
    78: 'mouth_left_inner',
    308: 'mouth_right_inner',
    82: 'upper_lip_left',
    312: 'upper_lip_right',
    95: 'lower_lip_left',
    324: 'lower_lip_right',
  };

  static const Map<String, FingerTrackingStatus> realisticFingerStatus =
      <String, FingerTrackingStatus>{
        'thumb': FingerTrackingStatus(
          status: 'observed',
          confidence: 0.94,
          evidenceFrames: 8,
        ),
        'index': FingerTrackingStatus(
          status: 'observed',
          confidence: 0.93,
          evidenceFrames: 8,
        ),
        'middle': FingerTrackingStatus(
          status: 'observed',
          confidence: 0.92,
          evidenceFrames: 8,
        ),
        'ring': FingerTrackingStatus(
          status: 'uncertain',
          confidence: 0.58,
          evidenceFrames: 6,
        ),
        'pinky': FingerTrackingStatus(
          status: 'observed',
          confidence: 0.90,
          evidenceFrames: 8,
        ),
      };

  static const Map<int, NormalizedPoint> poseCoordinates =
      <int, NormalizedPoint>{
        0: NormalizedPoint(x: 0.50, y: 0.16, z: -0.15),
        11: NormalizedPoint(x: 0.40, y: 0.35, z: -0.05),
        12: NormalizedPoint(x: 0.60, y: 0.35, z: -0.05),
        13: NormalizedPoint(x: 0.32, y: 0.47, z: -0.04),
        14: NormalizedPoint(x: 0.68, y: 0.47, z: -0.04),
        15: NormalizedPoint(x: 0.30, y: 0.58, z: -0.03),
        16: NormalizedPoint(x: 0.70, y: 0.58, z: -0.03),
        23: NormalizedPoint(x: 0.44, y: 0.66, z: 0),
        24: NormalizedPoint(x: 0.56, y: 0.66, z: 0),
        25: NormalizedPoint(x: 0.44, y: 0.82, z: 0.03),
        26: NormalizedPoint(x: 0.56, y: 0.82, z: 0.03),
      };

  static const Map<int, NormalizedPoint> leftHandImageCoordinates =
      <int, NormalizedPoint>{
        0: NormalizedPoint(x: 0.300, y: 0.580, z: -0.010),
        1: NormalizedPoint(x: 0.283, y: 0.555, z: -0.012),
        2: NormalizedPoint(x: 0.266, y: 0.535, z: -0.014),
        3: NormalizedPoint(x: 0.250, y: 0.515, z: -0.015),
        4: NormalizedPoint(x: 0.232, y: 0.500, z: -0.016),
        5: NormalizedPoint(x: 0.310, y: 0.520, z: -0.012),
        6: NormalizedPoint(x: 0.310, y: 0.475, z: -0.016),
        7: NormalizedPoint(x: 0.310, y: 0.435, z: -0.019),
        8: NormalizedPoint(x: 0.310, y: 0.395, z: -0.021),
        9: NormalizedPoint(x: 0.330, y: 0.515, z: -0.012),
        10: NormalizedPoint(x: 0.335, y: 0.465, z: -0.017),
        11: NormalizedPoint(x: 0.340, y: 0.420, z: -0.021),
        12: NormalizedPoint(x: 0.345, y: 0.380, z: -0.024),
        13: NormalizedPoint(x: 0.350, y: 0.520, z: -0.010),
        14: NormalizedPoint(x: 0.360, y: 0.480, z: -0.014),
        15: NormalizedPoint(x: 0.370, y: 0.445, z: -0.017),
        16: NormalizedPoint(x: 0.380, y: 0.415, z: -0.019),
        17: NormalizedPoint(x: 0.370, y: 0.535, z: -0.008),
        18: NormalizedPoint(x: 0.385, y: 0.505, z: -0.010),
        19: NormalizedPoint(x: 0.398, y: 0.480, z: -0.012),
        20: NormalizedPoint(x: 0.410, y: 0.460, z: -0.013),
      };

  /// Approximate MediaPipe hand-world values in metres, relative to the palm.
  static const Map<int, NormalizedPoint> rightHandWorldCoordinates =
      <int, NormalizedPoint>{
        0: NormalizedPoint(x: 0, y: 0, z: 0),
        1: NormalizedPoint(x: -0.018, y: -0.015, z: -0.004),
        2: NormalizedPoint(x: -0.034, y: -0.031, z: -0.006),
        3: NormalizedPoint(x: -0.049, y: -0.047, z: -0.006),
        4: NormalizedPoint(x: -0.064, y: -0.061, z: -0.005),
        5: NormalizedPoint(x: -0.030, y: -0.050, z: 0),
        6: NormalizedPoint(x: -0.033, y: -0.080, z: -0.002),
        7: NormalizedPoint(x: -0.035, y: -0.108, z: -0.003),
        8: NormalizedPoint(x: -0.036, y: -0.136, z: -0.004),
        9: NormalizedPoint(x: 0, y: -0.055, z: 0),
        10: NormalizedPoint(x: 0, y: -0.090, z: -0.002),
        11: NormalizedPoint(x: 0, y: -0.120, z: -0.003),
        12: NormalizedPoint(x: 0, y: -0.150, z: -0.004),
        13: NormalizedPoint(x: 0.025, y: -0.050, z: 0.001),
        14: NormalizedPoint(x: 0.029, y: -0.082, z: 0),
        15: NormalizedPoint(x: 0.032, y: -0.108, z: -0.001),
        16: NormalizedPoint(x: 0.034, y: -0.133, z: -0.002),
        17: NormalizedPoint(x: 0.045, y: -0.040, z: 0.002),
        18: NormalizedPoint(x: 0.052, y: -0.067, z: 0.001),
        19: NormalizedPoint(x: 0.057, y: -0.089, z: 0),
        20: NormalizedPoint(x: 0.061, y: -0.110, z: -0.001),
      };
}
