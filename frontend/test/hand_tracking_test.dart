import 'package:flutter_test/flutter_test.dart';

import 'package:apptesting/models/hand_tracking_models.dart';
import 'package:apptesting/models/face_tracking_models.dart';
import 'package:apptesting/models/tracking_models.dart';
import 'package:apptesting/services/hand_pose_normalizer.dart';
import 'package:apptesting/services/local_sign_sequence.dart';
import 'package:apptesting/services/tracking_service.dart';
import 'package:apptesting/services/utterance_stillness_detector.dart';

void main() {
  test('normalizes a detected hand into a skeleton frame', () {
    final hand = TrackedHand(
      handedness: Handedness.right,
      confidence: .92,
      landmarks: List<HandLandmark>.generate(
        21,
        (index) => HandLandmark(
          x: .4 + index * .005,
          y: .5 - index * .004,
          z: -.01 * index,
        ),
      ),
      fingerStatus: <String, FingerTrackingStatus>{
        'index': const FingerTrackingStatus(
          status: 'uncertain',
          confidence: .42,
          evidenceFrames: 8,
        ),
      },
    );
    final frame = HandPoseNormalizer().normalize(
      HandTrackingFrame(
        timestamp: DateTime.utc(2026, 9, 5),
        processingConfidence: .95,
        leftShoulder: const HandLandmark(x: .35, y: .42, z: 0, visibility: .9),
        rightShoulder: const HandLandmark(x: .65, y: .42, z: 0, visibility: .9),
        hands: <TrackedHand>[hand],
      ),
    );

    expect(frame.hands, hasLength(1));
    expect(frame.hands.single.landmarks, hasLength(21));
    expect(frame.rightHandVisible, isTrue);
    expect(frame.shouldersVisible, isTrue);
    expect(frame.handCoordinateAnalysis.single.jointCount, 21);
    expect(
      frame.handCoordinateAnalysis.single.coordinateSpace,
      'image_normalized_wrist_centered',
    );
    expect(frame.toJson()['hands'], hasLength(1));
    expect(frame.toJson()['hand_coordinate_analysis'], hasLength(1));
    expect(frame.hands.single.fingerStatus['index']?.displayLabel, 'uncertain');
    final roundTrip = TrackedHand.fromJson(hand.toJson());
    expect(roundTrip.fingerStatus['index']?.confidence, .42);
    expect(frame.featureVector, hasLength(322));
    expect(frame.toJson()['hand_motion'], isNull);
    expect(frame.toJson()['feature_vector'], isNull);
    final worlds = frame.toJson()['landmark_worlds'] as Map<String, dynamic>;
    expect(
      worlds.keys,
      containsAll(<String>['left_hand', 'right_hand', 'pose', 'face']),
    );
    expect(
      ((worlds['right_hand'] as Map<String, dynamic>)['finger_status']
          as Map<String, dynamic>)['index'],
      isNotNull,
    );
  });

  test('serializes a sign sequence for the analysis API', () {
    final frame = LandmarkFrame(
      timestamp: DateTime.utc(2026, 9, 5),
      hands: <TrackedHand>[],
    );
    final payload = SignSequencePayload(
      sessionId: 'session-test',
      sequenceId: 'sequence-test',
      language: 'ASL',
      startedAt: frame.timestamp,
      endedAt: frame.timestamp,
      frames: <LandmarkFrame>[frame],
      lexiconVersion: 'test-1',
    ).toJson();

    expect(payload['language'], 'ASL');
    expect(payload['frame_count'], 1);
    expect(payload['frames'], hasLength(1));
  });

  test('uses per-point confidence when calculating frame confidence', () {
    final hand = TrackedHand(
      handedness: Handedness.right,
      confidence: .9,
      landmarks: List<HandLandmark>.generate(
        21,
        (index) => HandLandmark(
          x: .4 + index * .005,
          y: .5 - index * .004,
          z: -.01 * index,
          visibility: .2,
        ),
      ),
    );
    final frame = HandPoseNormalizer().normalize(
      HandTrackingFrame(
        timestamp: DateTime.utc(2026, 9, 5),
        processingConfidence: .4,
        hands: <TrackedHand>[hand],
      ),
    );

    expect(frame.trackingConfidence, closeTo(.3, .0001));
  });

  test('keeps facial expression features in the frame payload', () {
    const face = FaceExpressionFeatures(
      confidence: .9,
      label: 'sad',
      landmarks: <FaceLandmark>[FaceLandmark(index: 1, x: .5, y: .3, z: -.02)],
      source: 'deepface',
      emotionScores: <String, double>{'sad': .86, 'neutral': .1},
    );
    final frame = HandPoseNormalizer().normalize(
      HandTrackingFrame(
        timestamp: DateTime.utc(2026, 9, 5),
        hands: const <TrackedHand>[],
        face: face,
      ),
    );

    expect(frame.faceExpression?.label, 'sad');
    expect(frame.faceExpression?.source, 'deepface');
    expect(frame.faceExpression?.emotionScores['sad'], .86);
    expect(frame.toJson()['face_expression'], isNotNull);
    expect(
      (frame.toJson()['face_expression'] as Map<String, dynamic>)['landmarks'],
      hasLength(1),
    );
  });

  test('simulates backend analysis without making a network request', () async {
    final frame = LandmarkFrame(
      timestamp: DateTime.utc(2026, 9, 5),
      hands: <TrackedHand>[
        TrackedHand(
          handedness: Handedness.right,
          confidence: .9,
          landmarks: List<HandLandmark>.generate(
            21,
            (index) => HandLandmark(
              x: .4 + index * .005,
              y: .5 - index * .004,
              z: -.01 * index,
            ),
          ),
        ),
      ],
    );
    final result = await SimulatedSignSequenceApiClient().analyze(
      SignSequencePayload(
        sessionId: 'session-test',
        sequenceId: 'sequence-test',
        language: 'ASL',
        startedAt: frame.timestamp,
        endedAt: frame.timestamp,
        frames: <LandmarkFrame>[frame],
        lexiconVersion: 'test-1',
      ),
    );

    expect(result.status, 'simulated');
    expect(result.detail, contains('no network request sent'));
  });

  test('captures only the frames between start and finish', () async {
    final tracking = DemoTrackingService();
    final frame = LandmarkFrame(timestamp: DateTime.utc(2026, 9, 5));

    tracking.ingest(frame);
    expect(tracking.isCapturingUtterance, isFalse);
    expect(tracking.utteranceFrames, isEmpty);

    tracking.beginUtterance();
    tracking.ingest(frame);
    expect(tracking.isCapturingUtterance, isTrue);
    expect(tracking.utteranceFrames, hasLength(1));
    expect(tracking.utteranceFrames.single, same(frame));

    final captured = await tracking.finishUtterance();
    expect(captured, hasLength(1));
    expect(captured.single, same(frame));
    expect(tracking.isCapturingUtterance, isFalse);
    expect(tracking.utteranceFrames, isEmpty);
    tracking.dispose();
  });

  test('detects a sustained pause after movement', () {
    final detector = UtteranceStillnessDetector(
      pauseDuration: const Duration(milliseconds: 100),
      minimumCaptureDuration: const Duration(milliseconds: 0),
    );
    final moving = _handFrame(
      timestamp: DateTime.utc(2026, 9, 5, 0, 0, 0, 0),
      xOffset: 0,
    );
    final moved = _handFrame(
      timestamp: DateTime.utc(2026, 9, 5, 0, 0, 0, 100),
      xOffset: .05,
    );
    final paused = _handFrame(
      timestamp: DateTime.utc(2026, 9, 5, 0, 0, 0, 250),
      xOffset: .05,
    );
    final pausedLongEnough = _handFrame(
      timestamp: DateTime.utc(2026, 9, 5, 0, 0, 0, 350),
      xOffset: .05,
    );

    expect(detector.update(moving), isFalse);
    expect(detector.update(moved), isFalse);
    expect(detector.update(paused), isFalse);
    expect(detector.update(pausedLongEnough), isTrue);
  });

  test('finishes despite ordinary live-tracker jitter after a sign', () {
    final detector = UtteranceStillnessDetector(
      minimumCaptureDuration: const Duration(milliseconds: 0),
    );
    final started = DateTime.utc(2026, 9, 5);

    expect(
      detector.update(_handFrame(timestamp: started, xOffset: 0)),
      isFalse,
    );
    expect(
      detector.update(
        _handFrame(
          timestamp: started.add(const Duration(milliseconds: 100)),
          xOffset: .06,
        ),
      ),
      isFalse,
    );
    // These sub-threshold movements model normal camera landmark noise, not
    // a continuing sign. They must not keep the capture open for seconds.
    expect(
      detector.update(
        _handFrame(
          timestamp: started.add(const Duration(milliseconds: 250)),
          xOffset: .07,
        ),
      ),
      isFalse,
    );
    expect(
      detector.update(
        _handFrame(
          timestamp: started.add(const Duration(milliseconds: 500)),
          xOffset: .081,
        ),
      ),
      isFalse,
    );
    expect(
      detector.update(
        _handFrame(
          timestamp: started.add(const Duration(milliseconds: 950)),
          xOffset: .092,
        ),
      ),
      isTrue,
    );
  });
}

LandmarkFrame _handFrame({
  required DateTime timestamp,
  required double xOffset,
}) => LandmarkFrame(
  timestamp: timestamp,
  trackingConfidence: .95,
  hands: <TrackedHand>[
    TrackedHand(
      handedness: Handedness.right,
      confidence: .95,
      landmarks: List<HandLandmark>.generate(
        21,
        (index) => HandLandmark(
          x: .4 + xOffset + index * .001,
          y: .5,
          z: 0,
          visibility: .95,
        ),
      ),
    ),
  ],
);
