import 'dart:async';

import '../models/hand_tracking_models.dart';
import '../models/tracking_models.dart';
import 'hand_pose_normalizer.dart';
import 'tracking_service.dart';
import 'web_hand_tracker_bridge.dart';

class WebTrackingService implements TrackingService {
  WebTrackingService({WebHandTrackerBridge? bridge})
    : _bridge = bridge ?? WebHandTrackerBridge();

  final WebHandTrackerBridge _bridge;
  final HandPoseNormalizer _normalizer = HandPoseNormalizer();
  final StreamController<LandmarkFrame> _controller =
      StreamController<LandmarkFrame>.broadcast();
  final TrackingSampleBuffer _confidenceWindow = TrackingSampleBuffer();
  final List<LandmarkFrame> _recentFrames = <LandmarkFrame>[];
  final List<LandmarkFrame> _utteranceFrames = <LandmarkFrame>[];
  LandmarkFrame? _latestFrame;
  StreamSubscription<HandTrackingFrame>? _subscription;
  StreamSubscription<String>? _healthSubscription;
  bool _started = false;
  bool _automaticRecoveryUsed = false;
  bool _recovering = false;
  bool _capturingUtterance = false;
  String _status = 'Waiting for camera';

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
  Future<void> start() async {
    if (_started) return;
    _status = 'Starting hand tracker';
    _utteranceFrames.clear();
    _capturingUtterance = false;
    _subscription = _bridge.frames.listen(ingestRaw);
    _healthSubscription = _bridge.healthEvents.listen(_onTrackerHealthEvent);
    try {
      await _bridge.start();
      _started = true;
      _automaticRecoveryUsed = false;
      _status = 'MediaPipe four-world tracking';
    } catch (_) {
      _status = 'Camera permission needed';
      await _subscription?.cancel();
      _subscription = null;
      await _healthSubscription?.cancel();
      _healthSubscription = null;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_started && _subscription == null) return;
    await _bridge.stop();
    await _subscription?.cancel();
    _subscription = null;
    await _healthSubscription?.cancel();
    _healthSubscription = null;
    _started = false;
    _automaticRecoveryUsed = false;
    _recovering = false;
    _capturingUtterance = false;
    _status = 'Camera stopped';
  }

  void ingestRaw(HandTrackingFrame raw) => ingest(_normalizer.normalize(raw));

  void _onTrackerHealthEvent(String event) {
    if (event != 'stalled' && event != 'stream_ended') return;
    unawaited(_recoverTrackerOnce(event));
  }

  Future<void> _recoverTrackerOnce(String event) async {
    if (!_started || _recovering) return;
    if (_automaticRecoveryUsed) {
      _status = 'Camera needs a manual restart';
      return;
    }

    _automaticRecoveryUsed = true;
    _recovering = true;
    _status = event == 'stream_ended'
        ? 'Camera stream ended · reconnecting'
        : 'Tracking paused · reconnecting';
    try {
      // Keep the Flutter frame subscription alive while only the browser
      // media/MediaPipe session is recreated. This preserves the user's UI
      // and avoids duplicate stream listeners after an idle tab resumes.
      await _bridge.stop();
      if (!_started) return;
      await _bridge.start();
      _status = 'MediaPipe tracking resumed';
    } catch (_) {
      _status = 'Camera needs a manual restart';
    } finally {
      _recovering = false;
    }
  }

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
    // A completed word is a hard temporal boundary. Do not let raw frames
    // from this word influence the next word's tracking state.
    _recentFrames.clear();
    _capturingUtterance = false;
    _status = 'MediaPipe four-world tracking · next sign';
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
    unawaited(stop());
    _bridge.dispose();
    _controller.close();
  }
}
