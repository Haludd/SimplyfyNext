import 'dart:async';

import 'package:apptesting/app_controller.dart';
import 'package:apptesting/contracts/landmark_stream.dart';
import 'package:apptesting/models/asl_recognition_models.dart';
import 'package:apptesting/models/face_tracking_models.dart';
import 'package:apptesting/models/hand_tracking_models.dart';
import 'package:apptesting/services/asl_recognizer_bridge.dart';
import 'package:apptesting/services/device_access_service.dart';
import 'package:apptesting/services/hand_pose_normalizer.dart';
import 'package:apptesting/services/landmark_batch_adapter.dart';
import 'package:apptesting/services/local_state_service.dart';
import 'package:apptesting/services/tracking_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/landmark_frame_fixtures.dart';

const _hello = AslRecognitionResult(
  status: 'recognized',
  word: 'hello',
  confidence: .91,
  modelVersion: 'jamesbustos_asl_250_809d456',
  frameCount: 25,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });

  test('browser camera geometry and face slots survive parsing, normalization and encoding', () {
    const indices = <int>[
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
    final raw = HandTrackingFrame.fromJson(<String, dynamic>{
      'timestamp_ms': 1000,
      'camera': <String, dynamic>{
        'source_width': 640,
        'source_height': 480,
        'rotation_degrees': 0,
        'mirrored_input': false,
        'coordinates_canonical': true,
      },
      'hands': <dynamic>[
        <String, dynamic>{
          'handedness': 'right',
          'confidence': .95,
          'landmarks': List<Map<String, dynamic>>.generate(
            21,
            (i) => <String, dynamic>{
              'x': .6 + i / 1000,
              'y': .3,
              'z': -.02,
              'visibility': .9,
            },
          ),
        },
      ],
      'landmark_worlds': <String, dynamic>{
        'face': <String, dynamic>{
          'upper': indices
              .map(
                (i) =>
                    FaceLandmark(index: i, x: i / 500, y: .2, z: -.01).toJson(),
              )
              .toList(),
          'mouth': <dynamic>[],
        },
      },
    });
    final normalized = HandPoseNormalizer()
        .normalize(raw)
        .copyWith(trackingConfidence: .9);
    final batch = LandmarkBatchEncoder(
      camera: const LandmarkCameraGeometry(
        sourceWidth: 1280,
        sourceHeight: 720,
        mirroredInput: true,
      ),
    ).buildBatch('123e4567-e89b-12d3-a456-426614174000', [normalized]);
    expect(batch.camera.toJson(), raw.cameraGeometry!.toJson());
    expect(batch.frames.single['left_hand'], isNull);
    final right = batch.frames.single['right_hand'] as List;
    expect(right.first, <double>[.6, .3, -.02, .9]);
    final face = batch.frames.single['face'] as List;
    expect(face, hasLength(16));
    for (var i = 0; i < indices.length; i++) {
      expect((face[i] as List).first, indices[i] / 500);
    }
  });

  test('a new hello result appears immediately and survives starting the next capture', () async {
    final (controller, tracking, bridge) = await _controller();
    addTearDown(controller.dispose);
    tracking.beginUtterance();
    tracking.ingest(LandmarkFrameFixtures.fullyTrackedFrame());
    await controller.analyzeSign();
    expect(controller.visibleAnalysis?.caption, 'hello');
    expect(controller.visibleAnalysis?.modelVersion, _hello.modelVersion);
    expect(bridge.finishCalls, 1);
    controller.startUtterance();
    expect(controller.visibleAnalysis?.caption, 'hello');
  });

  test(
    'an inference failure releases the capture lock so a retry works',
    () async {
      final (controller, tracking, bridge) = await _controller();
      addTearDown(controller.dispose);
      bridge.fail = true;
      tracking.beginUtterance();
      tracking.ingest(LandmarkFrameFixtures.fullyTrackedFrame());
      await controller.analyzeSign();
      expect(controller.analysisInFlight, isFalse);
      expect(controller.backendStatus, contains('Recognition unavailable'));
      bridge.fail = false;
      tracking.beginUtterance();
      tracking.ingest(LandmarkFrameFixtures.fullyTrackedFrame());
      await controller.analyzeSign();
      expect(controller.visibleAnalysis?.caption, 'hello');
    },
  );

  test(
    'language changes cancel pending ASL output and overlapping finishes',
    () async {
      final (controller, tracking, bridge) = await _controller();
      addTearDown(controller.dispose);
      bridge.pending = Completer<AslRecognitionResult?>();
      tracking.beginUtterance();
      tracking.ingest(LandmarkFrameFixtures.fullyTrackedFrame());
      final pending = controller.analyzeSign();
      await Future<void>.delayed(Duration.zero);
      await controller.analyzeSign();
      expect(bridge.finishCalls, 1);
      controller.setLanguage('BSL');
      bridge.pending!.complete(_hello);
      await pending;
      expect(controller.visibleAnalysis, isNull);
      expect(controller.analysisInFlight, isFalse);
    },
  );
}

Future<(AppController, DemoTrackingService, _Recognizer)> _controller() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final preferences = await SharedPreferences.getInstance();
  final tracking = DemoTrackingService();
  final bridge = _Recognizer();
  final controller = AppController(
    LocalStateService(preferences),
    tracking,
    DeviceAccessService(),
    aslRecognizer: bridge,
  )..audioEnabled = false;
  await Future<void>.delayed(Duration.zero);
  return (controller, tracking, bridge);
}

class _Recognizer extends AslRecognizerBridge {
  bool fail = false;
  int finishCalls = 0;
  Completer<AslRecognitionResult?>? pending;
  @override
  bool get isSupported => true;
  @override
  Future<AslRecognitionResult?> finishCapture() async {
    finishCalls++;
    if (fail) throw StateError('test runtime failure');
    return pending == null ? _hello : await pending!.future;
  }
}
