import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:apptesting/contracts/landmark_stream.dart';
import 'package:apptesting/models/hand_tracking_models.dart';
import 'package:apptesting/models/tracking_models.dart';
import 'package:apptesting/services/gloss_lattice_websocket_client.dart';
import 'package:apptesting/services/landmark_batch_adapter.dart';
import 'package:apptesting/services/landmark_stream_websocket_client.dart';

void main() {
  const sessionId = '123e4567-e89b-12d3-a456-426614174000';

  test('session request matches the backend-owned classifier contract', () {
    final request = LandmarkStreamSessionCreateRequest(
      language: 'sgsl',
      client: LandmarkStreamClientDescriptor(
        platform: LandmarkStreamClientPlatform.ios,
        appVersion: '1.0.0',
        deviceModel: 'test-device',
      ),
      detector: LandmarkStreamDetectorDescriptor(
        name: 'mediapipe-holistic',
        version: '0.10.35',
        delegate: LandmarkStreamDetectorDelegate.coreMl,
      ),
    );

    expect(request.toJson(), <String, dynamic>{
      'language': 'sgsl',
      'schema_version': '1.0',
      'stream_kind': 'landmarks',
      'client': <String, dynamic>{
        'platform': 'ios',
        'app_version': '1.0.0',
        'device_model': 'test-device',
      },
      'detector': <String, dynamic>{
        'name': 'mediapipe-holistic',
        'version': '0.10.35',
        'delegate': 'core_ml',
      },
    });
  });

  test('encoder emits fixed pose, hand, and face worlds', () {
    final encoder = LandmarkBatchEncoder(
      camera: const LandmarkCameraGeometry(
        sourceWidth: 1280,
        sourceHeight: 720,
        mirroredInput: true,
      ),
    );
    final frame = LandmarkFrame(
      timestamp: DateTime.utc(2026, 1, 1),
      subjectTracking: const SubjectTracking(locked: true),
      trackingConfidence: .87,
      hands: <TrackedHand>[
        TrackedHand(
          handedness: Handedness.left,
          confidence: .91,
          landmarks: List<HandLandmark>.generate(
            21,
            (index) => HandLandmark(
              x: index / 100,
              y: index / 200,
              z: -index / 300,
              visibility: .8,
            ),
          ),
        ),
      ],
      poseLandmarks: <PoseLandmark>[
        const PoseLandmark(
          index: 11,
          name: 'left_shoulder',
          x: .4,
          y: .4,
          z: 0,
        ),
      ],
    );

    final batch = encoder.buildBatch(sessionId, <LandmarkFrame>[frame]);
    final wire = jsonDecode(batch.toWireJson()) as Map<String, dynamic>;
    final encoded = (wire['frames'] as List).single as Map<String, dynamic>;

    expect(wire['type'], 'landmark_batch');
    expect(wire['schema_version'], '1.0');
    expect(encoded['subject_id'], 'subject-0');
    expect((encoded['pose'] as List).length, 9);
    expect((encoded['left_hand'] as List).length, 21);
    expect(encoded['right_hand'], isNull);
    expect((encoded['face'] as List).length, 16);
    expect(encoded['left_hand_score'], .91);
    expect(encoded['tracking_confidence'], .87);
  });

  test('landmark WebSocket waits for matching batch acknowledgements', () async {
    final channel = _FakeTextChannel();
    final events = <Map<String, dynamic>>[];
    final client = LandmarkStreamWebSocketClient(
      channel: channel,
      sessionId: sessionId,
      onEvent: events.add,
    );

    channel.emit(<String, dynamic>{'type': 'activity', 'state': 'idle'});
    await client.waitForInitialIdle();

    final batch = LandmarkBatch(
      sessionId: sessionId,
      batchSeq: 0,
      camera: const LandmarkCameraGeometry(
        sourceWidth: 1280,
        sourceHeight: 720,
        mirroredInput: true,
      ),
      frames: <Map<String, dynamic>>[
        <String, dynamic>{
          'seq': 0,
          'capture_ms': 0,
          'pose': null,
          'left_hand': null,
          'right_hand': null,
          'face': null,
          'left_hand_score': null,
          'right_hand_score': null,
          'tracking_confidence': .5,
        },
      ],
    );
    final ack = await client.sendBatch(batch);

    expect(ack.batchSeq, 0);
    expect(ack.receivedFrames, 1);
    expect(channel.sent.single['type'], 'landmark_batch');
    expect(events.map((event) => event['type']), contains('ack'));
    await client.close();
  });
}

final class _FakeTextChannel implements GlossLatticeTextChannel {
  final StreamController<String> _events = StreamController<String>();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<String> get stream => _events.stream;

  @override
  void sendText(String message) {
    final json = jsonDecode(message) as Map<String, dynamic>;
    sent.add(json);
    if (json['type'] == 'landmark_batch') {
      final frames = json['frames'] as List;
      emit(<String, dynamic>{
        'type': 'ack',
        'batch_seq': json['batch_seq'],
        'last_frame_seq': (frames.last as Map<String, dynamic>)['seq'],
        'received_frames': frames.length,
        'buffered_frames': frames.length,
        'dropped_frames': 0,
        'server_ms': 10,
      });
    }
  }

  void emit(Map<String, dynamic> event) => _events.add(jsonEncode(event));

  @override
  Future<void> close() async => _events.close();
}
