import 'package:apptesting/models/hand_tracking_models.dart';
import 'package:apptesting/models/state_normalisation_models.dart';
import 'package:apptesting/services/tracking_state_normalisation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/landmark_frame_fixtures.dart';

void main() {
  group('TrackingStateService with Harold canonical LandmarkFrame', () {
    test('perfect tracking is fully tracked with exact derived state', () {
      final input = LandmarkFrameFixtures.fullyTrackedFrame();
      final rawJson = input.toJson();

      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.tracked);
      expect(state.assessedQuality, closeTo(0.97, 1e-12));
      expect(state.issues, isEmpty);
      expect(state.canNormalise, isTrue);
      expect(state.trackingEpoch, 0);
      expect(state.hands, hasLength(2));
      expect(state.hands[0].sourceHandIndex, 0);
      expect(state.hands[0].trackId, 'hand-1');
      expect(state.hands[0].stableHandedness, Handedness.left);
      expect(
        state.hands[0].rightHandednessRunningAverage,
        closeTo(0.05, 1e-12),
      );
      expect(state.hands[0].handednessObservationCount, 1);
      expect(state.hands[0].handednessUncertain, isFalse);
      expect(state.hands[1].sourceHandIndex, 1);
      expect(state.hands[1].trackId, 'hand-2');
      expect(state.hands[1].stableHandedness, Handedness.right);
      expect(
        state.hands[1].rightHandednessRunningAverage,
        closeTo(0.95, 1e-12),
      );
      expect(state.hands[1].handednessObservationCount, 1);
      expect(state.hands[1].handednessUncertain, isFalse);
      expect(output.normalisation, isNull);

      // Stage 3 adds only namespaced runtime state. Harold's serialised frame
      // remains byte-for-byte equivalent at the data-structure level.
      expect(output.toJson(), equals(rawJson));
      expect(input.trackingState, isNull);
      expect(output.trackingConfidence, 0.97);
    });

    test('completely missing subject is absent without invented data', () {
      final input = LandmarkFrameFixtures.noSubjectFrame();
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.absent);
      expect(state.assessedQuality, 0);
      expect(
        state.issues,
        equals(<TrackingIssue>[
          TrackingIssue.noLandmarks,
          TrackingIssue.noHands,
          TrackingIssue.missingShoulders,
        ]),
      );
      expect(state.canNormalise, isFalse);
      expect(state.hands, isEmpty);
      expect(output.hands, isEmpty);
      expect(output.poseLandmarks, isEmpty);
      expect(output.faceUpperLandmarks, isEmpty);
      expect(output.faceMouthLandmarks, isEmpty);
      expect(output.leftShoulder, isNull);
      expect(output.rightShoulder, isNull);
      expect(output.trackingConfidence, 0);
      expect(output.toJson(), equals(input.toJson()));
    });

    test('one available shoulder degrades and cannot normalise', () {
      final input = LandmarkFrameFixtures.oneShoulderMissingFrame();
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.degraded);
      expect(state.assessedQuality, closeTo(0.90875, 1e-12));
      expect(
        state.issues,
        equals(<TrackingIssue>[TrackingIssue.missingShoulders]),
      );
      expect(state.canNormalise, isFalse);
      expect(output.leftShoulder, isNotNull);
      expect(output.rightShoulder, isNull);
      expect(output.poseLandmarks.any((point) => point.index == 12), isFalse);
      expect(output.toJson(), equals(input.toJson()));
    });

    test('nearly overlapping shoulders are rejected safely', () {
      final input = LandmarkFrameFixtures.tinyShoulderScaleFrame();
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.degraded);
      expect(state.assessedQuality, closeTo(0.97, 1e-12));
      expect(
        state.issues,
        equals(<TrackingIssue>[TrackingIssue.missingShoulders]),
      );
      expect(state.canNormalise, isFalse);
      expect(
        output.rightShoulder!.x - output.leftShoulder!.x,
        closeTo(0.000099, 1e-12),
      );
      expect(output.toJson(), equals(input.toJson()));
    });

    test('very large shoulder separation remains finite and tracked', () {
      final output = TrackingStateService().process(
        LandmarkFrameFixtures.largeShoulderScaleFrame(),
      );
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.tracked);
      expect(state.assessedQuality, closeTo(0.97, 1e-12));
      expect(state.issues, isEmpty);
      expect(state.canNormalise, isTrue);
      expect(
        output.rightShoulder!.x - output.leftShoulder!.x,
        closeTo(0.98, 1e-12),
      );
    });

    test('uniformly low visibility produces an absent state', () {
      final input = LandmarkFrameFixtures.lowConfidenceFrame();
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.absent);
      expect(state.assessedQuality, 0);
      expect(
        state.issues,
        equals(<TrackingIssue>[
          TrackingIssue.noLandmarks,
          TrackingIssue.noHands,
          TrackingIssue.missingShoulders,
          TrackingIssue.lowConfidence,
        ]),
      );
      expect(state.canNormalise, isFalse);
      expect(output.hands, hasLength(2));
      expect(output.hands.first.confidence, 0.95);
      expect(output.hands.first.landmarks.first.visibility, 0.1);
      expect(output.trackingConfidence, 0.1);
      expect(output.toJson(), equals(input.toJson()));
    });

    test('mixed point visibility degrades with exact assessed quality', () {
      final input = LandmarkFrameFixtures.mixedConfidenceFrame();
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;
      const expectedPoseQuality = (2 * 0.98) / 8;
      const expectedHandQuality = (11 * 0.96) / 21;
      const expectedQuality = (expectedPoseQuality + expectedHandQuality) / 2;

      expect(state.status, TrackingStatus.degraded);
      expect(state.assessedQuality, closeTo(expectedQuality, 1e-12));
      expect(
        state.issues,
        equals(<TrackingIssue>[TrackingIssue.lowConfidence]),
      );
      expect(state.canNormalise, isTrue);
      expect(output.hands.single.landmarks[10].visibility, 0.96);
      expect(output.hands.single.landmarks[11].visibility, 0.01);
      expect(output.trackingConfidence, 0.52);
      expect(output.toJson(), equals(input.toJson()));
    });

    test('missing hands degrades but valid shoulders remain normalisable', () {
      final input = LandmarkFrameFixtures.missingHandsFrame();
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.degraded);
      expect(state.assessedQuality, closeTo(0.49, 1e-12));
      expect(state.issues, equals(<TrackingIssue>[TrackingIssue.noHands]));
      expect(state.canNormalise, isTrue);
      expect(state.hands, isEmpty);
      expect(output.hands, isEmpty);
      expect(output.leftShoulder, isNotNull);
      expect(output.rightShoulder, isNotNull);
      expect(output.toJson(), equals(input.toJson()));
    });

    test('hands without pose degrade and cannot normalise', () {
      final input = LandmarkFrameFixtures.handsWithoutPoseFrame();
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.degraded);
      expect(state.assessedQuality, closeTo(0.48, 1e-12));
      expect(
        state.issues,
        equals(<TrackingIssue>[TrackingIssue.missingShoulders]),
      );
      expect(state.canNormalise, isFalse);
      expect(output.hands, hasLength(2));
      expect(output.poseLandmarks, isEmpty);
      expect(output.leftShoulder, isNull);
      expect(output.rightShoulder, isNull);
      expect(output.toJson(), equals(input.toJson()));
    });

    test('zero-visibility hand placeholder is retained, never fabricated', () {
      final input = LandmarkFrameFixtures.missingLandmarkFrame();
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;
      const leftHandQuality = 0.96;
      const rightHandQuality = (20 * 0.96) / 21;
      const expectedQuality =
          (0.98 + (leftHandQuality + rightHandQuality) / 2) / 2;
      final missing = output.hands[1].landmarks[8];

      expect(state.status, TrackingStatus.tracked);
      expect(state.assessedQuality, closeTo(expectedQuality, 1e-12));
      expect(
        state.issues,
        equals(<TrackingIssue>[TrackingIssue.lowConfidence]),
      );
      expect(missing.x, 0);
      expect(missing.y, 0);
      expect(missing.z, 0);
      expect(missing.visibility, 0);
      expect(missing.worldX, isNull);
      expect(missing.worldY, isNull);
      expect(missing.worldZ, isNull);
      expect(output.toJson(), equals(input.toJson()));
    });
  });

  group('TrackingStateService confidence boundaries', () {
    test('visibility exactly at 0.5 is accepted', () {
      final input = LandmarkFrameFixtures.confidenceBoundaryFrame(0.5);
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.tracked);
      expect(state.assessedQuality, closeTo(0.5, 1e-12));
      expect(state.issues, isEmpty);
      expect(state.canNormalise, isTrue);
      expect(output.trackingConfidence, 0.5);
      expect(output.toJson(), equals(input.toJson()));
    });

    test('visibility immediately below 0.5 is rejected', () {
      final input = LandmarkFrameFixtures.confidenceBoundaryFrame(0.499999);
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.absent);
      expect(state.assessedQuality, 0);
      expect(
        state.issues,
        equals(<TrackingIssue>[
          TrackingIssue.noLandmarks,
          TrackingIssue.noHands,
          TrackingIssue.missingShoulders,
          TrackingIssue.lowConfidence,
        ]),
      );
      expect(state.canNormalise, isFalse);
      expect(output.trackingConfidence, 0.499999);
      expect(output.toJson(), equals(input.toJson()));
    });

    test('visibility immediately above 0.5 is accepted', () {
      final input = LandmarkFrameFixtures.confidenceBoundaryFrame(0.500001);
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.tracked);
      expect(state.assessedQuality, closeTo(0.500001, 1e-12));
      expect(state.issues, isEmpty);
      expect(state.canNormalise, isTrue);
      expect(output.trackingConfidence, 0.500001);
      expect(output.toJson(), equals(input.toJson()));
    });
  });

  group('TrackingStateService handedness and subject state', () {
    test('ambiguous handedness remains represented and namespaced', () {
      final input = LandmarkFrameFixtures.ambiguousHandednessFrame();
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;
      final handState = state.hands.single;

      expect(state.status, TrackingStatus.tracked);
      expect(state.assessedQuality, closeTo(0.97, 1e-12));
      expect(
        state.issues,
        equals(<TrackingIssue>[TrackingIssue.handednessUncertain]),
      );
      expect(handState.sourceHandIndex, 0);
      expect(handState.trackId, 'hand-1');
      expect(handState.stableHandedness, Handedness.unknown);
      expect(handState.rightHandednessRunningAverage, 0.5);
      expect(handState.handednessObservationCount, 0);
      expect(handState.handednessUncertain, isTrue);
      expect(output.hands.single.handedness, Handedness.unknown);
      expect(output.hands.single.confidence, 0.5);
      expect(output.toJson(), equals(input.toJson()));
    });

    test(
      'duplicate raw handedness retains both hands and marks uncertainty',
      () {
        final input = LandmarkFrameFixtures.haroldFrame(
          hands: <TrackedHand>[
            LandmarkFrameFixtures.realisticHand(
              handedness: Handedness.right,
              wristX: 0.30,
            ),
            LandmarkFrameFixtures.realisticHand(
              handedness: Handedness.right,
              wristX: 0.70,
            ),
          ],
        );
        final output = TrackingStateService().process(input);
        final state = output.trackingState!;

        expect(state.status, TrackingStatus.tracked);
        expect(state.assessedQuality, closeTo(0.97, 1e-12));
        expect(
          state.issues,
          equals(<TrackingIssue>[TrackingIssue.handednessUncertain]),
        );
        expect(state.hands, hasLength(2));
        expect(state.hands.map((hand) => hand.trackId).toSet(), hasLength(2));
        expect(
          state.hands.every(
            (hand) => hand.stableHandedness == Handedness.right,
          ),
          isTrue,
        );
        expect(state.hands.every((hand) => hand.handednessUncertain), isTrue);
        expect(
          state.hands.every((hand) => hand.handednessObservationCount == 1),
          isTrue,
        );
        expect(
          output.hands.every((hand) => hand.handedness == Handedness.right),
          isTrue,
        );
        expect(output.toJson(), equals(input.toJson()));
      },
    );

    test('locked but currently invisible subject is absent', () {
      final base = LandmarkFrameFixtures.fullyTrackedFrame();
      final input = LandmarkFrameFixtures.copyFrame(
        base,
        subjectTracking: const SubjectTracking(
          locked: true,
          visible: false,
          centerX: 0.5,
          centerY: 0.42,
          area: 0.22,
          missingFrames: 1,
        ),
      );
      final output = TrackingStateService().process(input);
      final state = output.trackingState!;

      expect(state.status, TrackingStatus.absent);
      expect(state.assessedQuality, closeTo(0.97, 1e-12));
      expect(state.issues, isEmpty);
      expect(state.canNormalise, isTrue);
      expect(output.subjectTracking!.locked, isTrue);
      expect(output.subjectTracking!.visible, isFalse);
      expect(output.subjectTracking!.missingFrames, 1);
      expect(output.toJson(), equals(input.toJson()));
    });
  });

  test('Stage 3 preserves every canonical raw field and confidence', () {
    final input = LandmarkFrameFixtures.fullyTrackedFrame();
    final beforeJson = input.toJson();
    final originalRightTip = input.hands[1].landmarks[8];
    final originalPoseShoulder = input.poseLandmarks.singleWhere(
      (point) => point.index == 12,
    );

    final output = TrackingStateService().process(input);

    expect(output.toJson(), equals(beforeJson));
    expect(output.timestamp, input.timestamp);
    expect(output.trackingConfidence, same(input.trackingConfidence));
    expect(output.trackingConfidence, 0.97);
    expect(output.hands, same(input.hands));
    expect(output.hands[1], same(input.hands[1]));
    expect(output.hands[1].landmarks[8], same(originalRightTip));
    expect(output.hands[1].landmarks[8].x, originalRightTip.x);
    expect(output.hands[1].landmarks[8].worldX, originalRightTip.worldX);
    expect(output.hands[1].confidence, input.hands[1].confidence);
    expect(output.hands[1].fingerStatus, same(input.hands[1].fingerStatus));
    expect(output.hands[1].boundingBox, same(input.hands[1].boundingBox));
    expect(output.poseLandmarks, same(input.poseLandmarks));
    expect(
      output.poseLandmarks.singleWhere((point) => point.index == 12),
      same(originalPoseShoulder),
    );
    expect(output.faceUpperLandmarks, same(input.faceUpperLandmarks));
    expect(output.faceMouthLandmarks, same(input.faceMouthLandmarks));
    expect(output.faceExpression, same(input.faceExpression));
    expect(output.subjectTracking, same(input.subjectTracking));
    expect(output.handCoordinateAnalysis, same(input.handCoordinateAnalysis));
    expect(output.featureVector, same(input.featureVector));
    expect(output.lightingScore, input.lightingScore);
    expect(input.trackingState, isNull);
    expect(output.trackingState, isNotNull);
    expect(output.normalisation, isNull);
  });
}
