import 'package:apptesting/models/face_tracking_models.dart';
import 'package:apptesting/models/hand_coordinate_analysis.dart';
import 'package:apptesting/models/hand_tracking_models.dart';
import 'package:apptesting/models/state_normalisation_models.dart';
import 'package:apptesting/models/tracking_models.dart';
import 'package:apptesting/services/tracking_state_normalisation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/landmark_frame_fixtures.dart';

// Harold/MediaPipe LandmarkFrame -> already-assessed TrackingStateResult
// -> LandmarkNormalisationService -> frame.normalisation for segmentation.
//
// TrackingStateService is intentionally not invoked here, so a failure in
// these tests belongs to Stage 4 rather than Stage 3.
void main() {
  group('LandmarkNormalisationService - spatial output', () {
    test(
      'produces exact shoulder-relative coordinates and preserves raw data',
      () {
        final input = _withTrackingState(
          LandmarkFrameFixtures.fullyTrackedFrame(),
        );
        final rawJson = input.toJson();

        final output = LandmarkNormalisationService().process(input);
        final result = _result(output);

        expect(result.canNormalise, isTrue);
        expect(result.anchorIsStale, isFalse);
        _expectCoordinates(result.origin, x: 0.5, y: 0.35);
        expect(result.scale, closeTo(0.2, 1e-12));

        _expectCoordinates(
          _pointAt(result.poseLandmarks, 11).normalisedCoordinates,
          x: -0.5,
          y: 0,
        );
        _expectCoordinates(
          _pointAt(result.poseLandmarks, 12).normalisedCoordinates,
          x: 0.5,
          y: 0,
        );
        _expectCoordinates(
          _pointAt(result.poseLandmarks, 0).normalisedCoordinates,
          x: 0,
          y: -0.95,
        );
        _expectCoordinates(
          _handPointAt(
            result,
            sourceHandIndex: 0,
            landmarkIndex: 0,
          ).normalisedCoordinates,
          x: -1,
          y: 1.15,
        );
        _expectCoordinates(
          _handPointAt(
            result,
            sourceHandIndex: 0,
            landmarkIndex: 8,
          ).normalisedCoordinates,
          x: -0.95,
          y: 0.225,
        );
        _expectCoordinates(
          _handPointAt(
            result,
            sourceHandIndex: 1,
            landmarkIndex: 0,
          ).normalisedCoordinates,
          x: 1,
          y: 1.15,
        );

        // The additive Stage 4 result must not rewrite Harold's contract.
        expect(output.toJson(), equals(rawJson));
        expect(output.trackingConfidence, input.trackingConfidence);
        expect(identical(output.hands, input.hands), isTrue);
        expect(identical(output.poseLandmarks, input.poseLandmarks), isTrue);
        expect(
          identical(output.faceUpperLandmarks, input.faceUpperLandmarks),
          isTrue,
        );
        expect(
          identical(output.faceMouthLandmarks, input.faceMouthLandmarks),
          isTrue,
        );
        expect(identical(output.featureVector, input.featureVector), isTrue);
        expect(
          identical(
            output.handCoordinateAnalysis,
            input.handCoordinateAnalysis,
          ),
          isTrue,
        );
      },
    );

    test('is invariant to a common image translation and scale', () {
      final original = LandmarkFrameFixtures.fullyTrackedFrame();
      final transformed = _transformRawFrame(
        original,
        scale: 0.5,
        translateX: 0.25,
        translateY: 0.1,
      );

      final originalResult = _result(
        LandmarkNormalisationService().process(_withTrackingState(original)),
      );
      final transformedResult = _result(
        LandmarkNormalisationService().process(_withTrackingState(transformed)),
      );

      _expectDerivedListsEqual(
        originalResult.poseLandmarks,
        transformedResult.poseLandmarks,
      );
      _expectDerivedListsEqual(
        originalResult.faceUpperLandmarks,
        transformedResult.faceUpperLandmarks,
      );
      _expectDerivedListsEqual(
        originalResult.faceMouthLandmarks,
        transformedResult.faceMouthLandmarks,
      );
      expect(transformedResult.hands, hasLength(originalResult.hands.length));
      for (var index = 0; index < originalResult.hands.length; index += 1) {
        _expectDerivedListsEqual(
          originalResult.hands[index].landmarks,
          transformedResult.hands[index].landmarks,
        );
      }
    });

    test(
      'returns an empty, invalid result for a completely missing subject',
      () {
        final input = _withTrackingState(
          LandmarkFrameFixtures.noSubjectFrame(),
          status: TrackingStatus.absent,
          canNormalise: false,
        );

        final result = _result(LandmarkNormalisationService().process(input));

        expect(result.canNormalise, isFalse);
        expect(result.origin, isNull);
        expect(result.scale, isNull);
        expect(result.anchorIsStale, isFalse);
        expect(result.poseLandmarks, isEmpty);
        expect(result.faceUpperLandmarks, isEmpty);
        expect(result.faceMouthLandmarks, isEmpty);
        expect(result.hands, isEmpty);
      },
    );

    test('cannot establish an anchor with one or zero shoulders', () {
      for (final raw in <LandmarkFrame>[
        LandmarkFrameFixtures.oneShoulderMissingFrame(),
        LandmarkFrameFixtures.handsWithoutPoseFrame(),
      ]) {
        final result = _result(
          LandmarkNormalisationService().process(
            _withTrackingState(raw, canNormalise: false),
          ),
        );

        expect(result.canNormalise, isFalse);
        expect(result.origin, isNull);
        expect(result.scale, isNull);
        _expectAllBodyCoordinatesNull(result);
      }
    });

    test('rejects tiny scale, accepts the exact minimum, and handles a large scale', () {
      final tiny = _result(
        LandmarkNormalisationService().process(
          _withTrackingState(
            LandmarkFrameFixtures.tinyShoulderScaleFrame(),
            canNormalise: false,
          ),
        ),
      );
      expect(tiny.canNormalise, isFalse);
      expect(tiny.scale, isNull);
      _expectAllBodyCoordinatesNull(tiny);

      final minimum = _result(
        LandmarkNormalisationService().process(
          _withTrackingState(LandmarkFrameFixtures.minimumShoulderScaleFrame()),
        ),
      );
      expect(minimum.canNormalise, isTrue);
      expect(minimum.scale, closeTo(0.0001, 1e-15));
      _expectCoordinates(minimum.origin, x: 0.00005, y: 0.35);
      _expectEveryCoordinateFinite(minimum);

      final large = _result(
        LandmarkNormalisationService().process(
          _withTrackingState(LandmarkFrameFixtures.largeShoulderScaleFrame()),
        ),
      );
      expect(large.canNormalise, isTrue);
      expect(large.scale, closeTo(0.98, 1e-12));
      _expectCoordinates(large.origin, x: 0.5, y: 0.35);
      _expectCoordinates(
        _handPointAt(
          large,
          sourceHandIndex: 0,
          landmarkIndex: 0,
        ).normalisedCoordinates,
        x: -0.2 / 0.98,
        y: 0.23 / 0.98,
      );
      _expectEveryCoordinateFinite(large);
    });
  });

  group('LandmarkNormalisationService - confidence and absence', () {
    test('low confidence creates no anchor or body coordinates', () {
      final result = _result(
        LandmarkNormalisationService().process(
          _withTrackingState(
            LandmarkFrameFixtures.lowConfidenceFrame(),
            status: TrackingStatus.degraded,
            canNormalise: false,
          ),
        ),
      );

      expect(result.canNormalise, isFalse);
      expect(result.origin, isNull);
      expect(result.scale, isNull);
      _expectAllBodyCoordinatesNull(result);
    });

    test('mixed confidence gates each raw point independently', () {
      final result = _result(
        LandmarkNormalisationService().process(
          _withTrackingState(
            LandmarkFrameFixtures.mixedConfidenceFrame(),
            status: TrackingStatus.degraded,
          ),
        ),
      );

      expect(result.canNormalise, isTrue);
      expect(
        _pointAt(result.poseLandmarks, 11).normalisedCoordinates,
        isNotNull,
      );
      expect(_pointAt(result.poseLandmarks, 13).normalisedCoordinates, isNull);
      for (var index = 0; index < 21; index += 1) {
        final point = _handPointAt(
          result,
          sourceHandIndex: 0,
          landmarkIndex: index,
        );
        expect(
          point.normalisedCoordinates,
          index <= 10 ? isNotNull : isNull,
          reason: 'hand point $index must follow its own visibility',
        );
      }
    });

    test('zero-filled missing hand point remains null and clears history', () {
      final service = LandmarkNormalisationService();
      service.process(
        _withTrackingState(LandmarkFrameFixtures.fullyTrackedFrame()),
      );
      final missingInput = _withTrackingState(
        LandmarkFrameFixtures.missingLandmarkFrame(),
      );

      final output = service.process(missingInput);
      final point = _handPointAt(
        _result(output),
        sourceHandIndex: 1,
        landmarkIndex: 8,
      );

      expect(missingInput.hands[1].landmarks[8].x, 0);
      expect(missingInput.hands[1].landmarks[8].y, 0);
      expect(missingInput.hands[1].landmarks[8].z, 0);
      expect(missingInput.hands[1].landmarks[8].visibility, 0);
      expect(point.normalisedCoordinates, isNull);
      expect(point.velocity, isNull);
      expect(point.acceleration, isNull);
      expect(point.canonicalWorldCoordinates, isNull);
      expect(output.toJson(), equals(missingInput.toJson()));
    });

    test('a real image point at zero-zero remains valid when visibility is positive', () {
      final result = _result(
        LandmarkNormalisationService().process(
          _withTrackingState(LandmarkFrameFixtures.coordinateExtremesFrame()),
        ),
      );

      final wrist = _handPointAt(result, sourceHandIndex: 0, landmarkIndex: 0);
      _expectCoordinates(wrist.normalisedCoordinates, x: -0.5, y: -0.5);
      expect(wrist.source, LandmarkSource.mediaPipe);
    });
  });

  group('LandmarkNormalisationService - temporal output', () {
    test('first frame has positions but no velocity or acceleration', () {
      final result = _result(
        LandmarkNormalisationService().process(
          _withTrackingState(LandmarkFrameFixtures.fullyTrackedFrame()),
        ),
      );

      for (final point in _allDerivedPoints(result)) {
        expect(point.normalisedCoordinates, isNotNull);
        expect(point.velocity, isNull);
        expect(point.acceleration, isNull);
      }
    });

    test(
      'computes exact velocity and acceleration from capture timestamps',
      () {
        const config = TrackingStateNormalisationConfig(
          normalisationAnchorTimeConstant: Duration.zero,
          smoothingCutoffHz: double.infinity,
        );
        final service = LandmarkNormalisationService(config: config);
        final first = LandmarkFrameFixtures.fullyTrackedFrame();
        final second = LandmarkFrameFixtures.haroldFrame(
          timestamp: LandmarkFrameFixtures.epoch.add(
            const Duration(milliseconds: 100),
          ),
          hands: <TrackedHand>[
            LandmarkFrameFixtures.realisticHand(handedness: Handedness.left),
            LandmarkFrameFixtures.realisticHand(
              handedness: Handedness.right,
              wristX: 0.72,
            ),
          ],
        );
        final third = LandmarkFrameFixtures.haroldFrame(
          timestamp: LandmarkFrameFixtures.epoch.add(
            const Duration(milliseconds: 200),
          ),
          hands: <TrackedHand>[
            LandmarkFrameFixtures.realisticHand(handedness: Handedness.left),
            LandmarkFrameFixtures.realisticHand(
              handedness: Handedness.right,
              wristX: 0.76,
            ),
          ],
        );

        service.process(_withTrackingState(first));
        final secondPoint = _handPointAt(
          _result(service.process(_withTrackingState(second))),
          sourceHandIndex: 1,
          landmarkIndex: 0,
        );
        final thirdPoint = _handPointAt(
          _result(service.process(_withTrackingState(third))),
          sourceHandIndex: 1,
          landmarkIndex: 0,
        );

        _expectCoordinates(secondPoint.normalisedCoordinates, x: 1.1, y: 1.15);
        _expectCoordinates(secondPoint.velocity, x: 1, y: 0);
        expect(secondPoint.acceleration, isNull);
        _expectCoordinates(thirdPoint.normalisedCoordinates, x: 1.3, y: 1.15);
        _expectCoordinates(thirdPoint.velocity, x: 2, y: 0);
        _expectCoordinates(thirdPoint.acceleration, x: 10, y: 0);
      },
    );

    test('zero, negative, and excessive deltas reset derivatives safely', () {
      final cases = <String, Duration>{
        'zero': Duration.zero,
        'negative': const Duration(microseconds: -1),
        'over maximum': const Duration(milliseconds: 251),
      };

      for (final entry in cases.entries) {
        final service = LandmarkNormalisationService();
        service.process(
          _withTrackingState(LandmarkFrameFixtures.fullyTrackedFrame()),
        );
        final changed = LandmarkFrameFixtures.haroldFrame(
          timestamp: LandmarkFrameFixtures.epoch.add(entry.value),
          hands: <TrackedHand>[
            LandmarkFrameFixtures.realisticHand(handedness: Handedness.left),
            LandmarkFrameFixtures.realisticHand(
              handedness: Handedness.right,
              wristX: 0.72,
            ),
          ],
        );

        final point = _handPointAt(
          _result(service.process(_withTrackingState(changed))),
          sourceHandIndex: 1,
          landmarkIndex: 0,
        );

        expect(
          point.normalisedCoordinates?.isFinite,
          isTrue,
          reason: entry.key,
        );
        expect(point.velocity, isNull, reason: entry.key);
        expect(point.acceleration, isNull, reason: entry.key);
      }
    });

    test('missing and reappearing point restarts its derivative history', () {
      final service = LandmarkNormalisationService();
      service.process(
        _withTrackingState(LandmarkFrameFixtures.fullyTrackedFrame()),
      );
      final missing = service.process(
        _withTrackingState(LandmarkFrameFixtures.missingLandmarkFrame()),
      );
      final reappeared = service.process(
        _withTrackingState(LandmarkFrameFixtures.reappearingLandmarkFrame()),
      );

      expect(
        _handPointAt(
          _result(missing),
          sourceHandIndex: 1,
          landmarkIndex: 8,
        ).normalisedCoordinates,
        isNull,
      );
      final recovered = _handPointAt(
        _result(reappeared),
        sourceHandIndex: 1,
        landmarkIndex: 8,
      );
      expect(recovered.normalisedCoordinates, isNotNull);
      expect(recovered.velocity, isNull);
      expect(recovered.acceleration, isNull);
    });

    test('face coordinates are not smoothed', () {
      final service = LandmarkNormalisationService();
      final first = LandmarkFrameFixtures.fullyTrackedFrame();
      service.process(_withTrackingState(first));

      final movedUpper = <FaceLandmark>[
        for (final point in first.faceUpperLandmarks)
          point.index == LandmarkFrameFixtures.faceUpperIndices.first
              ? FaceLandmark(
                  index: point.index,
                  name: point.name,
                  x: 0.63,
                  y: point.y,
                  z: point.z,
                  visibility: point.visibility,
                )
              : point,
      ];
      final second = LandmarkFrameFixtures.copyFrame(
        first,
        timestamp: LandmarkFrameFixtures.atFrame(1),
        faceUpperLandmarks: movedUpper,
      );

      final result = _result(service.process(_withTrackingState(second)));
      final point = _pointAt(
        result.faceUpperLandmarks,
        LandmarkFrameFixtures.faceUpperIndices.first,
      );

      // (0.63 - shoulder midpoint 0.50) / shoulder width 0.20.
      _expectCoordinates(point.normalisedCoordinates, x: 0.65, y: -0.95);
      expect(point.velocity, isNotNull);
    });

    test('stale anchor remains valid at 500 ms and expires after it', () {
      final service = LandmarkNormalisationService();
      service.process(
        _withTrackingState(LandmarkFrameFixtures.fullyTrackedFrame()),
      );

      final at250 = service.process(
        _withTrackingState(
          LandmarkFrameFixtures.missingPoseFrame(
            timestamp: LandmarkFrameFixtures.epoch.add(
              const Duration(milliseconds: 250),
            ),
          ),
          canNormalise: false,
        ),
      );
      final at500 = service.process(
        _withTrackingState(
          LandmarkFrameFixtures.missingPoseFrame(
            timestamp: LandmarkFrameFixtures.epoch.add(
              const Duration(milliseconds: 500),
            ),
          ),
          canNormalise: false,
        ),
      );
      final at501 = service.process(
        _withTrackingState(
          LandmarkFrameFixtures.missingPoseFrame(
            timestamp: LandmarkFrameFixtures.epoch.add(
              const Duration(milliseconds: 501),
            ),
          ),
          canNormalise: false,
        ),
      );

      expect(_result(at250).canNormalise, isTrue);
      expect(_result(at250).anchorIsStale, isTrue);
      expect(_result(at500).canNormalise, isTrue);
      expect(_result(at500).anchorIsStale, isTrue);
      expect(_result(at500).scale, closeTo(0.2, 1e-12));
      expect(_result(at501).canNormalise, isFalse);
      expect(_result(at501).anchorIsStale, isFalse);
      expect(_result(at501).origin, isNull);
      expect(_result(at501).scale, isNull);
      _expectAllBodyCoordinatesNull(_result(at501));
    });
  });

  group('LandmarkNormalisationService - canonical hand world data', () {
    test('uses exact palm axes and skips an incomplete world triple', () {
      final hand = LandmarkFrameFixtures.realisticHand(
        handedness: Handedness.right,
        worldOverrides: const <int, NormalizedPoint>{
          0: NormalizedPoint(x: 0, y: 0, z: 0),
          5: NormalizedPoint(x: 1, y: 1, z: 0),
          17: NormalizedPoint(x: -1, y: 1, z: 0),
          8: NormalizedPoint(x: 2, y: 3, z: 4),
        },
      );
      final incomplete = _replaceHandPoint(
        hand,
        8,
        HandLandmark(
          x: hand.landmarks[8].x,
          y: hand.landmarks[8].y,
          z: hand.landmarks[8].z,
          worldX: 2,
          worldY: 3,
          worldZ: null,
          visibility: hand.landmarks[8].visibility,
        ),
      );
      final exactFrame = LandmarkFrameFixtures.haroldFrame(
        hands: <TrackedHand>[hand],
      );
      final incompleteFrame = LandmarkFrameFixtures.haroldFrame(
        hands: <TrackedHand>[incomplete],
      );

      final exact = _result(
        LandmarkNormalisationService().process(_withTrackingState(exactFrame)),
      );
      final exactHand = _handAt(exact, 0);
      _expectCoordinates(
        _pointAt(exactHand.landmarks, 0).canonicalWorldCoordinates,
        x: 0,
        y: 0,
        z: 0,
      );
      _expectCoordinates(
        _pointAt(exactHand.landmarks, 5).canonicalWorldCoordinates,
        x: 1,
        y: 1,
        z: 0,
      );
      _expectCoordinates(
        _pointAt(exactHand.landmarks, 17).canonicalWorldCoordinates,
        x: -1,
        y: 1,
        z: 0,
      );
      _expectCoordinates(
        _pointAt(exactHand.landmarks, 8).canonicalWorldCoordinates,
        x: 2,
        y: 3,
        z: 4,
      );

      final incompleteResult = _result(
        LandmarkNormalisationService().process(
          _withTrackingState(incompleteFrame),
        ),
      );
      final incompletePoint = _handPointAt(
        incompleteResult,
        sourceHandIndex: 0,
        landmarkIndex: 8,
      );
      expect(incompletePoint.canonicalWorldCoordinates, isNull);
      expect(incompletePoint.normalisedCoordinates, isNotNull);
      expect(
        _pointAt(
          _handAt(incompleteResult, 0).landmarks,
          5,
        ).canonicalWorldCoordinates,
        isNotNull,
      );
    });
  });
}

LandmarkFrame _withTrackingState(
  LandmarkFrame raw, {
  TrackingStatus status = TrackingStatus.tracked,
  bool canNormalise = true,
  int trackingEpoch = 1,
}) {
  final handStates = <TrackedHandState>[
    for (final entry in raw.hands.asMap().entries)
      TrackedHandState(
        sourceHandIndex: entry.key,
        trackId: 'epoch-$trackingEpoch-hand-${entry.key + 1}',
        stableHandedness: entry.value.handedness,
        rightHandednessRunningAverage: switch (entry.value.handedness) {
          Handedness.left => 0.05,
          Handedness.right => 0.95,
          Handedness.unknown => 0.5,
        },
        handednessObservationCount: 1,
        handednessUncertain: entry.value.handedness == Handedness.unknown,
      ),
  ];
  return raw.copyWith(
    trackingState: TrackingStateResult(
      status: status,
      assessedQuality: raw.trackingConfidence.clamp(0.0, 1.0).toDouble(),
      issues: const <TrackingIssue>[],
      canNormalise: canNormalise,
      trackingEpoch: trackingEpoch,
      hands: handStates,
    ),
  );
}

NormalisationResult _result(LandmarkFrame frame) {
  expect(frame.normalisation, isNotNull);
  return frame.normalisation!;
}

NormalisedHand _handAt(NormalisationResult result, int sourceHandIndex) =>
    result.hands.singleWhere((hand) => hand.sourceHandIndex == sourceHandIndex);

NormalisedLandmark _handPointAt(
  NormalisationResult result, {
  required int sourceHandIndex,
  required int landmarkIndex,
}) => _pointAt(_handAt(result, sourceHandIndex).landmarks, landmarkIndex);

NormalisedLandmark _pointAt(List<NormalisedLandmark> landmarks, int index) =>
    landmarks.singleWhere((point) => point.index == index);

void _expectCoordinates(
  LandmarkCoordinates? actual, {
  required double x,
  required double y,
  double? z,
  double tolerance = 1e-9,
}) {
  expect(actual, isNotNull);
  expect(actual!.x, closeTo(x, tolerance));
  expect(actual.y, closeTo(y, tolerance));
  if (z == null) {
    expect(actual.z, isNull);
  } else {
    expect(actual.z, isNotNull);
    expect(actual.z!, closeTo(z, tolerance));
  }
}

void _expectDerivedListsEqual(
  List<NormalisedLandmark> expected,
  List<NormalisedLandmark> actual,
) {
  expect(
    actual.map((point) => point.index),
    expected.map((point) => point.index),
  );
  for (final expectedPoint in expected) {
    final actualPoint = _pointAt(actual, expectedPoint.index);
    final expectedCoordinates = expectedPoint.normalisedCoordinates;
    if (expectedCoordinates == null) {
      expect(actualPoint.normalisedCoordinates, isNull);
    } else {
      _expectCoordinates(
        actualPoint.normalisedCoordinates,
        x: expectedCoordinates.x,
        y: expectedCoordinates.y,
        z: expectedCoordinates.z,
      );
    }
  }
}

Iterable<NormalisedLandmark> _allDerivedPoints(
  NormalisationResult result,
) sync* {
  yield* result.poseLandmarks;
  yield* result.faceUpperLandmarks;
  yield* result.faceMouthLandmarks;
  for (final hand in result.hands) {
    yield* hand.landmarks;
  }
}

void _expectAllBodyCoordinatesNull(NormalisationResult result) {
  for (final point in _allDerivedPoints(result)) {
    expect(
      point.normalisedCoordinates,
      isNull,
      reason: 'derived point ${point.index} must not be fabricated',
    );
    expect(point.velocity, isNull);
    expect(point.acceleration, isNull);
  }
}

void _expectEveryCoordinateFinite(NormalisationResult result) {
  for (final point in _allDerivedPoints(result)) {
    expect(point.normalisedCoordinates?.isFinite ?? true, isTrue);
    expect(point.velocity?.isFinite ?? true, isTrue);
    expect(point.acceleration?.isFinite ?? true, isTrue);
    expect(point.canonicalWorldCoordinates?.isFinite ?? true, isTrue);
  }
}

LandmarkFrame _transformRawFrame(
  LandmarkFrame source, {
  required double scale,
  required double translateX,
  required double translateY,
}) {
  NormalizedPoint? transformPoint(NormalizedPoint? point) => point == null
      ? null
      : NormalizedPoint(
          x: point.x * scale + translateX,
          y: point.y * scale + translateY,
          z: point.z,
          visibility: point.visibility,
        );

  final hands = <TrackedHand>[
    for (final hand in source.hands)
      TrackedHand(
        handedness: hand.handedness,
        confidence: hand.confidence,
        boundingBox: hand.boundingBox,
        fingerStatus: hand.fingerStatus,
        landmarks: <HandLandmark>[
          for (final point in hand.landmarks)
            HandLandmark(
              x: point.x * scale + translateX,
              y: point.y * scale + translateY,
              z: point.z,
              worldX: point.worldX,
              worldY: point.worldY,
              worldZ: point.worldZ,
              visibility: point.visibility,
            ),
        ],
      ),
  ];
  final subject = source.subjectTracking;
  return source.copyWith(
    leftShoulder: transformPoint(source.leftShoulder),
    rightShoulder: transformPoint(source.rightShoulder),
    leftWrist: transformPoint(source.leftWrist),
    rightWrist: transformPoint(source.rightWrist),
    hands: hands,
    handCoordinateAnalysis: const HandCoordinateAnalyzer().analyze(hands),
    poseLandmarks: <PoseLandmark>[
      for (final point in source.poseLandmarks)
        PoseLandmark(
          index: point.index,
          name: point.name,
          x: point.x * scale + translateX,
          y: point.y * scale + translateY,
          z: point.z,
          visibility: point.visibility,
          presence: point.presence,
        ),
    ],
    faceUpperLandmarks: _transformFace(
      source.faceUpperLandmarks,
      scale,
      translateX,
      translateY,
    ),
    faceMouthLandmarks: _transformFace(
      source.faceMouthLandmarks,
      scale,
      translateX,
      translateY,
    ),
    faceExpression: source.faceExpression == null
        ? null
        : FaceExpressionFeatures(
            confidence: source.faceExpression!.confidence,
            label: source.faceExpression!.label,
            source: source.faceExpression!.source,
            landmarks: _transformFace(
              source.faceExpression!.landmarks,
              scale,
              translateX,
              translateY,
            ),
            emotionScores: source.faceExpression!.emotionScores,
          ),
    subjectTracking: subject == null
        ? null
        : SubjectTracking(
            locked: subject.locked,
            visible: subject.visible,
            centerX: subject.centerX == null
                ? null
                : subject.centerX! * scale + translateX,
            centerY: subject.centerY == null
                ? null
                : subject.centerY! * scale + translateY,
            area: subject.area * scale * scale,
            missingFrames: subject.missingFrames,
          ),
  );
}

List<FaceLandmark> _transformFace(
  List<FaceLandmark> points,
  double scale,
  double translateX,
  double translateY,
) => <FaceLandmark>[
  for (final point in points)
    FaceLandmark(
      index: point.index,
      name: point.name,
      x: point.x * scale + translateX,
      y: point.y * scale + translateY,
      z: point.z,
      visibility: point.visibility,
    ),
];

TrackedHand _replaceHandPoint(
  TrackedHand source,
  int index,
  HandLandmark replacement,
) => TrackedHand(
  handedness: source.handedness,
  confidence: source.confidence,
  boundingBox: source.boundingBox,
  fingerStatus: source.fingerStatus,
  landmarks: <HandLandmark>[
    for (final entry in source.landmarks.asMap().entries)
      entry.key == index ? replacement : entry.value,
  ],
);
