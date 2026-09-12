import 'package:apptesting/models/hand_tracking_models.dart';
import 'package:apptesting/models/state_normalisation_models.dart';
import 'package:apptesting/services/tracking_state_normalisation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/landmark_frame_fixtures.dart';

void main() {
  group('LandmarkNormalisationService canonical boundary', () {
    test('adds namespaced results without changing Harold raw data', () {
      final input = LandmarkFrameFixtures.fullyTrackedFrame();
      final rawJson = input.toJson();

      final output = TrackingStateNormalisationService().process(input);

      expect(output.trackingState?.status, TrackingStatus.tracked);
      expect(output.normalisation?.canNormalise, isTrue);
      expect(output.normalisation?.origin?.x, closeTo(0.5, 1e-12));
      expect(output.normalisation?.origin?.y, closeTo(0.35, 1e-12));
      expect(output.normalisation?.scale, closeTo(0.2, 1e-12));

      final leftWrist = output.normalisation!.hands[0].landmarks[0];
      expect(leftWrist.normalisedCoordinates?.x, closeTo(-1, 1e-12));
      expect(leftWrist.normalisedCoordinates?.y, closeTo(1.15, 1e-12));
      expect(leftWrist.velocity, isNull);
      expect(leftWrist.acceleration, isNull);

      expect(output.toJson(), equals(rawJson));
      expect(identical(output.hands, input.hands), isTrue);
      expect(identical(output.poseLandmarks, input.poseLandmarks), isTrue);
      expect(output.trackingConfidence, input.trackingConfidence);
    });

    test('does not normalise when one shoulder is missing', () {
      final input = LandmarkFrameFixtures.oneShoulderMissingFrame();

      final output = TrackingStateNormalisationService().process(input);

      expect(output.trackingState?.canNormalise, isFalse);
      expect(output.normalisation?.canNormalise, isFalse);
      expect(output.normalisation?.origin, isNull);
      expect(output.normalisation?.scale, isNull);
      for (final hand in output.normalisation!.hands) {
        for (final point in hand.landmarks) {
          expect(point.normalisedCoordinates, isNull);
          expect(point.velocity, isNull);
          expect(point.acceleration, isNull);
        }
      }
    });

    test(
      'pose wrist substitution is derived and raw hand point stays absent',
      () {
        final missingWristHand = LandmarkFrameFixtures.realisticHand(
          handedness: Handedness.left,
          missingIndices: const <int>{0},
        );
        final input = LandmarkFrameFixtures.haroldFrame(
          hands: <TrackedHand>[missingWristHand],
        );
        final rawJson = input.toJson();

        final output = TrackingStateNormalisationService().process(input);
        final handState = output.trackingState!.hands.single;
        final normalisedWrist = output.normalisation!.hands.single.landmarks[0];

        expect(
          handState.poseWristSubstituteCoordinates?.x,
          closeTo(0.3, 1e-12),
        );
        expect(
          handState.poseWristSubstituteCoordinates?.y,
          closeTo(0.58, 1e-12),
        );
        expect(handState.poseWristSubstituteVisibility, closeTo(0.98, 1e-12));
        expect(normalisedWrist.source, LandmarkSource.poseWristSubstitution);
        expect(normalisedWrist.normalisedCoordinates?.x, closeTo(-1, 1e-12));
        expect(normalisedWrist.normalisedCoordinates?.y, closeTo(1.15, 1e-12));

        expect(output.hands.single.landmarks.first.x, 0);
        expect(output.hands.single.landmarks.first.y, 0);
        expect(output.hands.single.landmarks.first.z, 0);
        expect(output.hands.single.landmarks.first.visibility, 0);
        expect(output.toJson(), equals(rawJson));
      },
    );

    test('incomplete world triple prevents canonical world calculation', () {
      final complete = LandmarkFrameFixtures.realisticHand(
        handedness: Handedness.right,
      );
      final points = List<HandLandmark>.of(complete.landmarks);
      final point = points[5];
      points[5] = HandLandmark(
        x: point.x,
        y: point.y,
        z: point.z,
        worldX: point.worldX,
        worldY: point.worldY,
        visibility: point.visibility,
      );
      final hand = TrackedHand(
        handedness: complete.handedness,
        confidence: complete.confidence,
        landmarks: points,
        boundingBox: complete.boundingBox,
        fingerStatus: complete.fingerStatus,
      );
      final input = LandmarkFrameFixtures.haroldFrame(
        hands: <TrackedHand>[hand],
      );

      final output = TrackingStateNormalisationService().process(input);

      expect(
        output.normalisation!.hands.single.landmarks.map(
          (point) => point.canonicalWorldCoordinates,
        ),
        everyElement(isNull),
      );
      final rawPoint =
          (output.toJson()['hands'] as List<dynamic>).single['landmarks'][5]
              as Map<String, dynamic>;
      expect(rawPoint.containsKey('world_x'), isTrue);
      expect(rawPoint.containsKey('world_y'), isTrue);
      expect(rawPoint.containsKey('world_z'), isFalse);
    });

    test('reset clears temporal derivative history', () {
      final service = TrackingStateNormalisationService(
        config: const TrackingStateNormalisationConfig(
          normalisationAnchorTimeConstant: Duration.zero,
        ),
      );
      final first = LandmarkFrameFixtures.fullyTrackedFrame();
      final second = LandmarkFrameFixtures.haroldFrame(
        timestamp: LandmarkFrameFixtures.atFrame(1),
        hands: <TrackedHand>[
          LandmarkFrameFixtures.realisticHand(
            handedness: Handedness.left,
            wristX: 0.31,
          ),
          LandmarkFrameFixtures.realisticHand(handedness: Handedness.right),
        ],
      );

      service.process(first);
      final moving = service.process(second);
      expect(moving.normalisation!.hands[0].landmarks[0].velocity, isNotNull);

      service.reset();
      final afterReset = service.process(
        LandmarkFrameFixtures.copyFrame(
          second,
          timestamp: LandmarkFrameFixtures.atFrame(2),
        ),
      );
      expect(afterReset.normalisation!.hands[0].landmarks[0].velocity, isNull);
      expect(
        afterReset.normalisation!.hands[0].landmarks[0].acceleration,
        isNull,
      );
    });
  });
}
