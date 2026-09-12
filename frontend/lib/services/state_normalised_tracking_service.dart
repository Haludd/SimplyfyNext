import 'dart:async';

import '../models/tracking_models.dart';
import 'tracking_service.dart';
import 'tracking_state_normalisation_service.dart';

/// Connects Harold's Stage 1/2 stream to the Stage 3/4 processor.
///
/// The upstream service still owns the camera and MediaPipe. This decorator
/// owns only derived tracking state, body-relative normalisation, and the
/// processed frame buffers exposed to the next stage.
final class StateNormalisedTrackingService implements TrackingService {
  StateNormalisedTrackingService(
    this.upstream, {
    TrackingStateNormalisationService? stateNormalisation,
  }) : stateNormalisation =
           stateNormalisation ?? TrackingStateNormalisationService() {
    _subscription = upstream.frames.listen(
      _acceptUpstreamFrame,
      onError: _controller.addError,
      onDone: _controller.close,
    );
  }

  final TrackingService upstream;
  final TrackingStateNormalisationService stateNormalisation;
  final StreamController<LandmarkFrame> _controller =
      StreamController<LandmarkFrame>.broadcast();
  final TrackingSampleBuffer _confidenceWindow = TrackingSampleBuffer();
  final List<LandmarkFrame> _recentFrames = <LandmarkFrame>[];
  final List<LandmarkFrame> _utteranceFrames = <LandmarkFrame>[];

  late final StreamSubscription<LandmarkFrame> _subscription;
  LandmarkFrame? _latestFrame;
  bool _capturingUtterance = false;
  bool _disposed = false;

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
  String get status => upstream.status;

  @override
  Future<void> start() => upstream.start();

  @override
  Future<void> stop() async {
    try {
      await upstream.stop();
    } finally {
      _resetProcessedState();
    }
  }

  @override
  void beginUtterance() {
    _checkNotDisposed();
    upstream.beginUtterance();
    _utteranceFrames.clear();
    _capturingUtterance = true;
  }

  @override
  Future<List<LandmarkFrame>> finishUtterance() async {
    _checkNotDisposed();
    await upstream.finishUtterance();
    // An asynchronous upstream controller may still have queued its final
    // frame. Yield once before closing the local capture window.
    await Future<void>.delayed(Duration.zero);
    _capturingUtterance = false;
    final result = List<LandmarkFrame>.unmodifiable(_utteranceFrames);
    _utteranceFrames.clear();
    return result;
  }

  /// Test/manual input hook. Normal production input arrives from the
  /// upstream MediaPipe service and is never generated here.
  @override
  void ingest(LandmarkFrame frame) {
    _checkNotDisposed();
    upstream.ingest(frame);
  }

  void _acceptUpstreamFrame(LandmarkFrame rawFrame) {
    if (_disposed) return;
    try {
      final processed = stateNormalisation.process(rawFrame);
      _latestFrame = processed;
      _recentFrames.add(processed);
      if (_capturingUtterance) _utteranceFrames.add(processed);
      if (_recentFrames.length > 180) _recentFrames.removeAt(0);
      if (_utteranceFrames.length > 600) _utteranceFrames.removeAt(0);
      _confidenceWindow.add(processed.trackingConfidence, processed.timestamp);
      if (!_controller.isClosed) _controller.add(processed);
    } catch (error, stackTrace) {
      if (!_controller.isClosed) _controller.addError(error, stackTrace);
    }
  }

  void _resetProcessedState() {
    stateNormalisation.reset();
    _latestFrame = null;
    _recentFrames.clear();
    _utteranceFrames.clear();
    _capturingUtterance = false;
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('StateNormalisedTrackingService is disposed.');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_subscription.cancel());
    upstream.dispose();
    unawaited(_controller.close());
  }
}
