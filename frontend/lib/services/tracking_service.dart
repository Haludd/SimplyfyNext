import 'dart:async';

import '../models/tracking_models.dart';

abstract class TrackingService {
  Stream<LandmarkFrame> get frames;
  LandmarkFrame? get latestFrame;
  TrackingSampleBuffer get confidenceWindow;
  List<LandmarkFrame> get recentFrames;
  List<LandmarkFrame> get utteranceFrames;
  int get utteranceFrameCount;
  bool get isCapturingUtterance;
  String get status;
  Future<void> start();
  Future<void> stop();
  void beginUtterance();
  Future<List<LandmarkFrame>> finishUtterance();
  void ingest(LandmarkFrame frame);
  void dispose();
}

/// The UI consumes this interface, so MediaPipe Tasks can be connected without
/// duplicating alignment, confidence, or custom-sign logic.
class DemoTrackingService implements TrackingService {
  DemoTrackingService() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      ingest(
        LandmarkFrame(
          timestamp: now,
          leftShoulder: const NormalizedPoint(x: 0.39, y: 0.56),
          rightShoulder: const NormalizedPoint(x: 0.61, y: 0.56),
          leftWrist: const NormalizedPoint(x: 0.27, y: 0.74),
          rightWrist: const NormalizedPoint(x: 0.73, y: 0.74),
          leftHandVisible: true,
          rightHandVisible: true,
          trackingConfidence: 0.98,
          featureVector: const <double>[
            0.39,
            0.56,
            0.61,
            0.56,
            0.27,
            0.74,
            0.73,
            0.74,
          ],
        ),
      );
    });
  }

  final StreamController<LandmarkFrame> _controller =
      StreamController<LandmarkFrame>.broadcast();
  final TrackingSampleBuffer _confidenceWindow = TrackingSampleBuffer();
  final List<LandmarkFrame> _recentFrames = <LandmarkFrame>[];
  final List<LandmarkFrame> _utteranceFrames = <LandmarkFrame>[];
  LandmarkFrame? _latestFrame;
  bool _capturingUtterance = false;
  String _status = 'Demo tracking';
  late final Timer _timer;

  @override
  Stream<LandmarkFrame> get frames => _controller.stream;

  @override
  LandmarkFrame? get latestFrame => _latestFrame;

  @override
  TrackingSampleBuffer get confidenceWindow => _confidenceWindow;

  @override
  List<LandmarkFrame> get recentFrames =>
      List<LandmarkFrame>.unmodifiable(_recentFrames);

  @override
  List<LandmarkFrame> get utteranceFrames =>
      List<LandmarkFrame>.unmodifiable(_utteranceFrames);

  @override
  int get utteranceFrameCount => _utteranceFrames.length;

  @override
  bool get isCapturingUtterance => _capturingUtterance;

  @override
  String get status => _status;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void beginUtterance() {
    _utteranceFrames.clear();
    _capturingUtterance = true;
    _status = 'Capturing LandmarkFrame data';
  }

  @override
  Future<List<LandmarkFrame>> finishUtterance() async {
    final frames = List<LandmarkFrame>.unmodifiable(_utteranceFrames);
    _utteranceFrames.clear();
    _capturingUtterance = false;
    _status = 'Demo tracking · ready for next utterance';
    return frames;
  }

  @override
  void ingest(LandmarkFrame frame) {
    _latestFrame = frame;
    _recentFrames.add(frame);
    if (_capturingUtterance) _utteranceFrames.add(frame);
    if (_recentFrames.length > 180) _recentFrames.removeAt(0);
    if (_utteranceFrames.length > 600) _utteranceFrames.removeAt(0);
    _confidenceWindow.add(frame.trackingConfidence, frame.timestamp);
    if (!_controller.isClosed) _controller.add(frame);
  }

  @override
  void dispose() {
    _timer.cancel();
    _controller.close();
  }
}
