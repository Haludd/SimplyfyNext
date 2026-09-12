import 'dart:async';

import 'package:apptesting/models/hand_tracking_models.dart';
import 'package:apptesting/models/tracking_models.dart';
import 'package:apptesting/services/hand_pose_normalizer.dart';
import 'package:apptesting/services/state_normalised_tracking_service.dart';
import 'package:apptesting/services/tracking_service.dart';
import 'package:apptesting/services/web_hand_tracker_bridge.dart';
import 'package:apptesting/services/web_tracking_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/landmark_frame_fixtures.dart';

void main() {
  group('Harold Stage 1/2 integration', () {
    test('maps realistic MediaPipe output into the shared LandmarkFrame', () {
      final expected = LandmarkFrameFixtures.fullyTrackedFrame();
      final raw = _asHaroldDetectorFrame(expected);

      final actual = HandPoseNormalizer().normalize(raw);

      expect(actual.timestamp, expected.timestamp);
      expect(actual.hands, hasLength(2));
      expect(actual.hands.first.handedness, Handedness.left);
      expect(actual.hands.first.confidence, expected.hands.first.confidence);
      expect(actual.hands.first.landmarks, hasLength(21));
      expect(
        actual.hands.first.landmarks.first.visibility,
        expected.hands.first.landmarks.first.visibility,
      );
      expect(actual.hands.first.landmarks.first.worldX, isNotNull);
      expect(actual.poseLandmarks, hasLength(expected.poseLandmarks.length));
      expect(actual.faceUpperLandmarks, hasLength(24));
      expect(actual.faceMouthLandmarks, hasLength(12));
      expect(actual.subjectTracking?.locked, isTrue);
      expect(actual.subjectTracking?.visible, isTrue);
      expect(actual.leftShoulder?.x, closeTo(expected.leftShoulder!.x, 1e-12));
      expect(
        actual.rightShoulder?.x,
        closeTo(expected.rightShoulder!.x, 1e-12),
      );
      expect(actual.trackingState, isNull);
      expect(actual.normalisation, isNull);
    });

    test('does not fabricate an absent MediaPipe subject', () {
      final raw = HandTrackingFrame(
        timestamp: LandmarkFrameFixtures.epoch,
        hands: const <TrackedHand>[],
        subjectTracking: const SubjectTracking(
          locked: false,
          visible: false,
          area: 0,
          missingFrames: 4,
        ),
        processingConfidence: 0,
      );

      final actual = HandPoseNormalizer().normalize(raw);

      expect(actual.hands, isEmpty);
      expect(actual.poseLandmarks, isEmpty);
      expect(actual.faceUpperLandmarks, isEmpty);
      expect(actual.faceMouthLandmarks, isEmpty);
      expect(actual.leftShoulder, isNull);
      expect(actual.rightShoulder, isNull);
      expect(actual.leftWrist, isNull);
      expect(actual.rightWrist, isNull);
      expect(actual.trackingConfidence, 0);
    });

    test('real Stage 1/2 service feeds the Stage 3/4 decorator', () async {
      final bridge = _FakeWebHandTrackerBridge();
      final stage12 = WebTrackingService(bridge: bridge);
      final stage34 = StateNormalisedTrackingService(stage12);
      addTearDown(stage34.dispose);
      await stage34.start();
      final nextFrame = stage34.frames.first;

      bridge.emit(
        _asHaroldDetectorFrame(LandmarkFrameFixtures.fullyTrackedFrame()),
      );
      final processed = await nextFrame;

      expect(processed.trackingState?.status.name, 'tracked');
      expect(processed.normalisation?.canNormalise, isTrue);
      expect(stage12.latestFrame?.trackingState, isNull);
      expect(stage12.latestFrame?.normalisation, isNull);
      await stage34.stop();
    });
  });

  group('Stage 1/2 -> Stage 3/4 stream', () {
    late _FakeTrackingService upstream;
    late StateNormalisedTrackingService service;

    setUp(() {
      upstream = _FakeTrackingService();
      service = StateNormalisedTrackingService(upstream);
    });

    tearDown(() => service.dispose());

    test(
      'every published frame contains separate Stage 3 and Stage 4 results',
      () async {
        final raw = LandmarkFrameFixtures.fullyTrackedFrame();
        final nextFrame = service.frames.first;

        upstream.ingest(raw);
        final processed = await nextFrame;

        expect(raw.trackingState, isNull);
        expect(raw.normalisation, isNull);
        expect(processed.trackingState?.status.name, 'tracked');
        expect(processed.trackingState?.canNormalise, isTrue);
        expect(processed.normalisation?.canNormalise, isTrue);
        expect(processed.normalisation?.origin, isNotNull);
        expect(processed.normalisation?.scale, closeTo(0.20, 1e-12));
        expect(service.latestFrame, same(processed));
        expect(service.recentFrames.single, same(processed));
      },
    );

    test(
      'utterance buffer exposes processed frames, never upstream raw frames',
      () async {
        service.beginUtterance();
        upstream.ingest(LandmarkFrameFixtures.fullyTrackedFrame());
        upstream.ingest(
          LandmarkFrameFixtures.fullyTrackedFrame(
            timestamp: LandmarkFrameFixtures.atFrame(1),
          ),
        );

        final frames = await service.finishUtterance();

        expect(frames, hasLength(2));
        expect(
          frames,
          everyElement(
            predicate<LandmarkFrame>((frame) {
              return frame.trackingState != null && frame.normalisation != null;
            }),
          ),
        );
        expect(service.utteranceFrameCount, 0);
        expect(service.isCapturingUtterance, isFalse);
      },
    );

    test(
      'finish includes the last frame from an asynchronous upstream',
      () async {
        final asyncUpstream = _FakeTrackingService(sync: false);
        final asyncService = StateNormalisedTrackingService(asyncUpstream);
        addTearDown(asyncService.dispose);

        asyncService.beginUtterance();
        asyncUpstream.ingest(LandmarkFrameFixtures.fullyTrackedFrame());
        final frames = await asyncService.finishUtterance();

        expect(frames, hasLength(1));
        expect(frames.single.trackingState, isNotNull);
        expect(frames.single.normalisation, isNotNull);
      },
    );

    test('stopping the camera resets Stage 3/4 temporal history', () async {
      upstream.ingest(LandmarkFrameFixtures.fullyTrackedFrame());
      upstream.ingest(
        LandmarkFrameFixtures.discontinuityFrame(
          timestamp: LandmarkFrameFixtures.atFrame(1),
        ),
      );
      expect(_hasVelocity(service.latestFrame!), isTrue);

      await service.stop();
      await service.start();
      upstream.ingest(
        LandmarkFrameFixtures.fullyTrackedFrame(
          timestamp: LandmarkFrameFixtures.atFrame(2),
        ),
      );

      expect(_hasVelocity(service.latestFrame!), isFalse);
      expect(upstream.stopCalls, 1);
      expect(upstream.startCalls, 1);
    });

    test(
      'missing input remains missing after both processing stages',
      () async {
        upstream.ingest(LandmarkFrameFixtures.noSubjectFrame());
        final processed = service.latestFrame!;

        expect(processed.trackingState?.status.name, 'absent');
        expect(processed.normalisation?.canNormalise, isFalse);
        expect(processed.normalisation?.hands, isEmpty);
        expect(processed.normalisation?.poseLandmarks, isEmpty);
        expect(processed.hands, isEmpty);
        expect(processed.poseLandmarks, isEmpty);
      },
    );
  });
}

HandTrackingFrame _asHaroldDetectorFrame(LandmarkFrame frame) =>
    HandTrackingFrame(
      timestamp: frame.timestamp,
      hands: frame.hands,
      face: frame.faceExpression,
      leftShoulder: _asHandPoint(frame.leftShoulder),
      rightShoulder: _asHandPoint(frame.rightShoulder),
      poseLandmarks: frame.poseLandmarks,
      faceUpperLandmarks: frame.faceUpperLandmarks,
      faceMouthLandmarks: frame.faceMouthLandmarks,
      subjectTracking: frame.subjectTracking,
      processingConfidence: frame.trackingConfidence,
    );

HandLandmark? _asHandPoint(NormalizedPoint? point) => point == null
    ? null
    : HandLandmark(
        x: point.x,
        y: point.y,
        z: point.z,
        visibility: point.visibility,
      );

bool _hasVelocity(LandmarkFrame frame) => frame.normalisation!.hands
    .expand((hand) => hand.landmarks)
    .any((landmark) => landmark.velocity != null);

final class _FakeWebHandTrackerBridge extends WebHandTrackerBridge {
  final StreamController<HandTrackingFrame> _frames =
      StreamController<HandTrackingFrame>.broadcast(sync: true);

  @override
  Stream<HandTrackingFrame> get frames => _frames.stream;

  void emit(HandTrackingFrame frame) => _frames.add(frame);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() => unawaited(_frames.close());
}

final class _FakeTrackingService implements TrackingService {
  _FakeTrackingService({bool sync = true})
    : _controller = StreamController<LandmarkFrame>.broadcast(sync: sync);

  final StreamController<LandmarkFrame> _controller;
  final TrackingSampleBuffer _confidenceWindow = TrackingSampleBuffer();
  final List<LandmarkFrame> _recent = <LandmarkFrame>[];
  final List<LandmarkFrame> _utterance = <LandmarkFrame>[];

  LandmarkFrame? _latest;
  bool _capturing = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<LandmarkFrame> get frames => _controller.stream;

  @override
  LandmarkFrame? get latestFrame => _latest;

  @override
  TrackingSampleBuffer get confidenceWindow => _confidenceWindow;

  @override
  List<LandmarkFrame> get recentFrames => List.unmodifiable(_recent);

  @override
  List<LandmarkFrame> get utteranceFrames => List.unmodifiable(_utterance);

  @override
  int get utteranceFrameCount => _utterance.length;

  @override
  bool get isCapturingUtterance => _capturing;

  @override
  String get status => 'fake Harold tracker';

  @override
  Future<void> start() async => startCalls += 1;

  @override
  Future<void> stop() async {
    stopCalls += 1;
    _capturing = false;
  }

  @override
  void beginUtterance() {
    _utterance.clear();
    _capturing = true;
  }

  @override
  Future<List<LandmarkFrame>> finishUtterance() async {
    _capturing = false;
    final result = List<LandmarkFrame>.unmodifiable(_utterance);
    _utterance.clear();
    return result;
  }

  @override
  void ingest(LandmarkFrame frame) {
    _latest = frame;
    _recent.add(frame);
    if (_capturing) _utterance.add(frame);
    _confidenceWindow.add(frame.trackingConfidence, frame.timestamp);
    _controller.add(frame);
  }

  @override
  void dispose() {
    unawaited(_controller.close());
  }
}
