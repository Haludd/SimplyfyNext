import 'package:apptesting/models/face_tracking_models.dart';
import 'package:apptesting/models/hand_tracking_models.dart';
import 'package:apptesting/models/state_normalisation_models.dart';
import 'package:apptesting/models/tracking_models.dart';
import 'package:apptesting/services/tracking_state_normalisation_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/landmark_frame_fixtures.dart';

void main() {
  group('TrackingStateService temporal identity', () {
    test('keeps track IDs when Harold changes the hand-list order', () {
      final service = TrackingStateService();
      final firstInput = LandmarkFrameFixtures.fullyTrackedFrame();
      final firstState = _trackingState(service.process(firstInput));

      final reorderedInput = LandmarkFrameFixtures.copyFrame(
        firstInput,
        timestamp: LandmarkFrameFixtures.atFrame(1),
        hands: firstInput.hands.reversed.toList(growable: false),
      );
      final reordered = service.process(reorderedInput);
      final reorderedState = _trackingState(reordered);

      expect(reordered.hands[0].handedness, Handedness.right);
      expect(reordered.hands[1].handedness, Handedness.left);
      expect(reorderedState.hands[0].trackId, firstState.hands[1].trackId);
      expect(reorderedState.hands[1].trackId, firstState.hands[0].trackId);
      expect(reorderedState.hands[0].sourceHandIndex, 0);
      expect(reorderedState.hands[1].sourceHandIndex, 1);
      expect(reorderedState.trackingEpoch, firstState.trackingEpoch);
    });

    test('uses handedness-aware global matching while hands cross', () {
      final service = TrackingStateService();
      final firstInput = LandmarkFrameFixtures.haroldFrame(
        hands: <TrackedHand>[
          LandmarkFrameFixtures.realisticHand(
            handedness: Handedness.left,
            wristX: 0.30,
          ),
          LandmarkFrameFixtures.realisticHand(
            handedness: Handedness.right,
            wristX: 0.70,
          ),
        ],
      );
      final firstState = _trackingState(service.process(firstInput));

      final crossedInput = LandmarkFrameFixtures.copyFrame(
        firstInput,
        timestamp: LandmarkFrameFixtures.atFrame(1),
        hands: <TrackedHand>[
          LandmarkFrameFixtures.realisticHand(
            handedness: Handedness.left,
            wristX: 0.55,
          ),
          LandmarkFrameFixtures.realisticHand(
            handedness: Handedness.right,
            wristX: 0.45,
          ),
        ],
      );
      final crossedState = _trackingState(service.process(crossedInput));

      expect(crossedState.hands[0].trackId, firstState.hands[0].trackId);
      expect(crossedState.hands[1].trackId, firstState.hands[1].trackId);
      expect(
        crossedState.hands.map((state) => state.stableHandedness),
        <Handedness>[Handedness.left, Handedness.right],
      );
    });

    test('keeps stable handedness and updates the running average after one raw label flip', () {
      final service = TrackingStateService();
      final firstInput = LandmarkFrameFixtures.haroldFrame(
        hands: <TrackedHand>[
          LandmarkFrameFixtures.realisticHand(
            handedness: Handedness.right,
            handednessConfidence: 0.90,
            wristX: 0.70,
          ),
        ],
      );
      final firstHandState = _trackingState(service.process(firstInput))
          .hands
          .single;

      final flippedRawHand = LandmarkFrameFixtures.realisticHand(
        handedness: Handedness.left,
        handednessConfidence: 0.90,
        wristX: 0.69,
      );
      final flippedInput = LandmarkFrameFixtures.copyFrame(
        firstInput,
        timestamp: LandmarkFrameFixtures.atFrame(1),
        hands: <TrackedHand>[flippedRawHand],
      );
      final flipped = service.process(flippedInput);
      final flippedHandState = _trackingState(flipped).hands.single;

      expect(flipped.hands.single.handedness, Handedness.left);
      expect(flipped.hands.single.confidence, 0.90);
      expect(flippedHandState.trackId, firstHandState.trackId);
      expect(flippedHandState.stableHandedness, Handedness.right);
      expect(
        flippedHandState.rightHandednessRunningAverage,
        closeTo(0.50, 1e-12),
      );
      expect(flippedHandState.handednessObservationCount, 2);
    });

    test(
      'retains duplicate labels and marks both derived states uncertain',
      () {
        final service = TrackingStateService();
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

        final output = service.process(input);
        final state = _trackingState(output);

        expect(output.hands, hasLength(2));
        expect(
          output.hands.map((hand) => hand.handedness),
          everyElement(Handedness.right),
        );
        expect(state.hands.map((hand) => hand.trackId).toSet(), hasLength(2));
        expect(
          state.hands.map((hand) => hand.handednessUncertain),
          everyElement(isTrue),
        );
        expect(state.issues, contains(TrackingIssue.handednessUncertain));
      },
    );

    test('stores a pose-wrist substitute only in TrackedHandState and preserves raw landmark zero', () {
      final service = TrackingStateService();
      final rawHand = LandmarkFrameFixtures.realisticHand(
        handedness: Handedness.left,
        coordinateOverrides: const <int, NormalizedPoint>{
          0: NormalizedPoint(x: 0.10, y: 0.10, z: -0.20),
        },
        visibilityOverrides: const <int, double>{0: 0.10},
      );
      final input = LandmarkFrameFixtures.haroldFrame(
        hands: <TrackedHand>[rawHand],
      );

      final output = service.process(input);
      final handState = _trackingState(output).hands.single;

      expect(identical(output.hands.single, rawHand), isTrue);
      expect(
        identical(output.hands.single.landmarks[0], rawHand.landmarks[0]),
        isTrue,
      );
      expect(output.hands.single.landmarks[0].x, 0.10);
      expect(output.hands.single.landmarks[0].y, 0.10);
      expect(output.hands.single.landmarks[0].z, -0.20);
      expect(output.hands.single.landmarks[0].visibility, 0.10);
      expect(handState.poseWristSubstituteCoordinates, isNotNull);
      expect(handState.poseWristSubstituteCoordinates!.x, 0.30);
      expect(handState.poseWristSubstituteCoordinates!.y, 0.58);
      expect(handState.poseWristSubstituteCoordinates!.z, -0.03);
      expect(handState.poseWristSubstituteVisibility, 0.98);
    });

    test('expires a track only after the configured missing-frame count', () {
      final service = TrackingStateService(
        config: const TrackingStateNormalisationConfig(trackExpiryFrames: 2),
      );
      final firstInput = LandmarkFrameFixtures.haroldFrame(
        hands: <TrackedHand>[
          LandmarkFrameFixtures.realisticHand(handedness: Handedness.left),
        ],
      );
      final firstState = _trackingState(service.process(firstInput));
      final firstTrackId = firstState.hands.single.trackId;

      for (var offset = 1; offset <= 3; offset += 1) {
        service.process(
          LandmarkFrameFixtures.copyFrame(
            firstInput,
            timestamp: LandmarkFrameFixtures.atFrame(offset),
            hands: const <TrackedHand>[],
            handCoordinateAnalysis: const [],
            leftHandVisible: false,
            rightHandVisible: false,
          ),
        );
      }

      final returned = service.process(
        LandmarkFrameFixtures.copyFrame(
          firstInput,
          timestamp: LandmarkFrameFixtures.atFrame(4),
        ),
      );
      final returnedState = _trackingState(returned);

      expect(returnedState.trackingEpoch, firstState.trackingEpoch);
      expect(returnedState.hands.single.trackId, isNot(firstTrackId));
      expect(returnedState.hands.single.trackId, 'hand-2');
      expect(returnedState.hands.single.handednessObservationCount, 1);
    });
  });

  group('TrackingStateService tracking epochs', () {
    final timestampCases = <({String name, DateTime timestamp})>[
      (name: 'zero time delta', timestamp: LandmarkFrameFixtures.epoch),
      (
        name: 'negative time delta',
        timestamp: LandmarkFrameFixtures.epoch.subtract(
          const Duration(microseconds: 1),
        ),
      ),
      (
        name: 'time gap above the 250 ms limit',
        timestamp: LandmarkFrameFixtures.epoch.add(
          const Duration(milliseconds: 251),
        ),
      ),
    ];

    for (final timestampCase in timestampCases) {
      test('${timestampCase.name} starts a new tracking epoch', () {
        final service = TrackingStateService();
        final firstInput = LandmarkFrameFixtures.fullyTrackedFrame();
        final firstState = _trackingState(service.process(firstInput));

        final next = service.process(
          LandmarkFrameFixtures.copyFrame(
            firstInput,
            timestamp: timestampCase.timestamp,
          ),
        );
        final nextState = _trackingState(next);

        expect(firstState.trackingEpoch, 0);
        expect(nextState.trackingEpoch, 1);
        expect(
          nextState.hands.map((hand) => hand.handednessObservationCount),
          everyElement(1),
        );
      });
    }

    test('a temporarily invisible but still-locked subject keeps its epoch and hand tracks', () {
      final service = TrackingStateService();
      final firstInput = LandmarkFrameFixtures.fullyTrackedFrame();
      final firstState = _trackingState(service.process(firstInput));

      final hiddenInput = LandmarkFrameFixtures.copyFrame(
        firstInput,
        timestamp: LandmarkFrameFixtures.atFrame(1),
        leftShoulder: null,
        rightShoulder: null,
        leftWrist: null,
        rightWrist: null,
        leftHandVisible: false,
        rightHandVisible: false,
        trackingConfidence: 0,
        hands: const <TrackedHand>[],
        handCoordinateAnalysis: const [],
        poseLandmarks: const <PoseLandmark>[],
        faceUpperLandmarks: const <FaceLandmark>[],
        faceMouthLandmarks: const <FaceLandmark>[],
        faceExpression: null,
        subjectTracking: const SubjectTracking(
          locked: true,
          visible: false,
          area: 0,
          missingFrames: 1,
        ),
      );
      final hiddenState = _trackingState(service.process(hiddenInput));

      final recovered = service.process(
        LandmarkFrameFixtures.copyFrame(
          firstInput,
          timestamp: LandmarkFrameFixtures.atFrame(2),
        ),
      );
      final recoveredState = _trackingState(recovered);

      expect(hiddenState.status, TrackingStatus.absent);
      expect(hiddenState.trackingEpoch, firstState.trackingEpoch);
      expect(recoveredState.trackingEpoch, firstState.trackingEpoch);
      expect(recoveredState.hands[0].trackId, firstState.hands[0].trackId);
      expect(recoveredState.hands[1].trackId, firstState.hands[1].trackId);
    });

    test('loss of subject lock starts a new epoch', () {
      final service = TrackingStateService();
      final firstInput = LandmarkFrameFixtures.fullyTrackedFrame();
      final firstState = _trackingState(service.process(firstInput));

      final unlocked = service.process(
        LandmarkFrameFixtures.copyFrame(
          firstInput,
          timestamp: LandmarkFrameFixtures.atFrame(1),
          subjectTracking: const SubjectTracking(
            locked: false,
            visible: false,
            area: 0,
            missingFrames: 1,
          ),
        ),
      );
      final unlockedState = _trackingState(unlocked);

      final relocked = service.process(
        LandmarkFrameFixtures.copyFrame(
          firstInput,
          timestamp: LandmarkFrameFixtures.atFrame(2),
        ),
      );
      final relockedState = _trackingState(relocked);

      expect(firstState.trackingEpoch, 0);
      expect(unlockedState.trackingEpoch, 1);
      expect(
        unlockedState.hands.map((hand) => hand.handednessObservationCount),
        everyElement(1),
      );
      expect(relockedState.trackingEpoch, 1);
      expect(
        relockedState.hands.map((hand) => hand.handednessObservationCount),
        everyElement(2),
      );
    });
  });

  test('canonical JSON projection excludes the namespaced Stage 3 result', () {
    final input = LandmarkFrameFixtures.fullyTrackedFrame();
    final output = TrackingStateService().process(input);
    final json = output.toJson();

    expect(output.trackingState, isNotNull);
    expect(output.normalisation, isNull);
    expect(json, input.toJson());
    expect(json, isNot(contains('tracking_state')));
    expect(json, isNot(contains('trackingState')));
    expect(json, isNot(contains('tracking_epoch')));
    expect(json, isNot(contains('tracking_status')));
  });

  test('canonical JSON projection keeps Harold exact key nesting', () {
    final json = LandmarkFrameFixtures.noSubjectFrame().toJson();

    expect(json.keys.toList(), <String>[
      'timestamp',
      'tracking_confidence',
      'left_shoulder',
      'right_shoulder',
      'hands',
      'hand_coordinate_analysis',
      'face_expression',
      'subject_tracking',
      'landmark_worlds',
    ]);
    expect(json['left_shoulder'], isNull);
    expect(json['right_shoulder'], isNull);
    expect(json['hands'], isEmpty);
    expect(json['face_expression'], isNull);

    final subject = json['subject_tracking']! as Map<String, dynamic>;
    expect(subject, <String, dynamic>{
      'locked': false,
      'visible': true,
      'area': 0.0,
      'missing_frames': 0,
    });

    final worlds = json['landmark_worlds']! as Map<String, dynamic>;
    expect(worlds.keys.toList(), <String>[
      'left_hand',
      'right_hand',
      'pose',
      'face',
    ]);
    for (final side in const <String>['left_hand', 'right_hand']) {
      final hand = worlds[side]! as Map<String, dynamic>;
      expect(hand.keys.toList(), <String>[
        'handedness',
        'confidence',
        'finger_status',
        'landmarks',
      ]);
      expect(hand['landmarks'], isEmpty);
    }
    expect((worlds['pose']! as Map<String, dynamic>).keys, <String>[
      'landmarks',
    ]);
    expect((worlds['face']! as Map<String, dynamic>).keys.toList(), <String>[
      'upper',
      'mouth',
      'emotion',
    ]);
  });

  test('canonical fixture uses Harold curated face names and defaults', () {
    final frame = LandmarkFrameFixtures.fullyTrackedFrame();

    expect(
      frame.faceUpperLandmarks
          .map((point) => '${point.index}:${point.name}')
          .toList(),
      LandmarkFrameFixtures.faceUpperIndices
          .map(
            (index) => '$index:${LandmarkFrameFixtures.faceUpperNames[index]}',
          )
          .toList(),
    );
    expect(
      frame.faceMouthLandmarks
          .map((point) => '${point.index}:${point.name}')
          .toList(),
      LandmarkFrameFixtures.faceMouthIndices
          .map(
            (index) => '$index:${LandmarkFrameFixtures.faceMouthNames[index]}',
          )
          .toList(),
    );
    expect(
      frame.hands,
      everyElement(
        predicate<TrackedHand>((hand) {
          return hand.landmarks.length == 21 && hand.boundingBox.isEmpty;
        }),
      ),
    );
    expect(frame.faceExpression?.landmarks, isEmpty);
    expect(frame.featureVector, hasLength(322));
  });
}

TrackingStateResult _trackingState(LandmarkFrame frame) {
  final state = frame.trackingState;
  expect(state, isNotNull);
  return state!;
}
