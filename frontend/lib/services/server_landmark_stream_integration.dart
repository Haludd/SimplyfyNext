import 'dart:async';

import '../contracts/landmark_stream.dart';
import '../models/tracking_models.dart';
import 'landmark_batch_adapter.dart';
import 'landmark_stream_connection_factory.dart';
import 'landmark_stream_session_client.dart';
import 'landmark_stream_websocket_client.dart';
import 'tracking_service.dart';

/// Composition root for the server-side recognition architecture.
///
/// The frontend owns camera capture and MediaPipe. The Railway backend owns
/// body-relative normalisation, utterance segmentation, classification,
/// confidence policy, and caption generation. This class sends bounded
/// `landmark_batch` messages and forwards every backend event to the UI.
final class ServerLandmarkStreamIntegration {
  ServerLandmarkStreamIntegration._({
    required this.session,
    required this.tracking,
    required this.sessionClient,
    required this.socket,
    required this.encoder,
    required this.onBatchSent,
    required this.onError,
  });

  static Future<ServerLandmarkStreamIntegration> connect({
    required Uri httpsBaseUri,
    required Uri websocketBaseUri,
    required LandmarkStreamSessionCreateRequest request,
    required TrackingService tracking,
    required LandmarkCameraGeometry camera,
    String subjectId = 'subject-0',
    Duration sessionTimeout = const Duration(seconds: 15),
    Duration connectTimeout = const Duration(seconds: 15),
    Duration responseTimeout = const Duration(seconds: 60),
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(LandmarkBatch batch)? onBatchSent,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    final sessionClient = LandmarkStreamSessionClient(
      baseUri: httpsBaseUri,
      requestTimeout: sessionTimeout,
    );
    LandmarkStreamSession? negotiatedSession;
    try {
      final session = await sessionClient.createSession(request);
      negotiatedSession = session;
      final channel = await LandmarkStreamConnectionFactory(
        connectTimeout: connectTimeout,
      ).connect(
        websocketBaseUri: websocketBaseUri,
        websocketPath: session.websocketPath,
        streamToken: session.streamToken,
      );
      final socket = LandmarkStreamWebSocketClient(
        channel: channel,
        sessionId: session.sessionId,
        responseTimeout: responseTimeout,
        onEvent: onEvent,
      );
      try {
        await socket.waitForInitialIdle();
      } on Object {
        await socket.close();
        rethrow;
      }
      return ServerLandmarkStreamIntegration._(
        session: session,
        tracking: tracking,
        sessionClient: sessionClient,
        socket: socket,
        encoder: LandmarkBatchEncoder(camera: camera, subjectId: subjectId),
        onBatchSent: onBatchSent,
        onError: onError,
      );
    } on Object {
      if (negotiatedSession != null) {
        try {
          await sessionClient.deleteSession(negotiatedSession);
        } on Object {
          // The original connection/session error is more useful to callers.
        }
      }
      sessionClient.close();
      rethrow;
    }
  }

  final LandmarkStreamSession session;
  final TrackingService tracking;
  final LandmarkStreamSessionClient sessionClient;
  final LandmarkStreamWebSocketClient socket;
  final LandmarkBatchEncoder encoder;
  final void Function(LandmarkBatch batch)? onBatchSent;
  final void Function(Object error, StackTrace stackTrace)? onError;

  final List<LandmarkFrame> _pendingFrames = <LandmarkFrame>[];
  StreamSubscription<LandmarkFrame>? _frameSubscription;
  Future<void> _sendTail = Future<void>.value();
  bool _started = false;
  bool _closed = false;

  bool get isStarted => _started;
  bool get isClosed => _closed || socket.isClosed;

  Future<void> start({bool startTracking = true}) async {
    _checkOpen();
    if (_started) return;
    _frameSubscription = tracking.frames.listen(
      _acceptFrame,
      onError: (Object error, StackTrace stackTrace) =>
          _reportError(error, stackTrace),
    );
    _started = true;
    try {
      await socket.start();
      if (startTracking) await tracking.start();
    } on Object {
      _started = false;
      await _frameSubscription?.cancel();
      _frameSubscription = null;
      rethrow;
    }
  }

  void _acceptFrame(LandmarkFrame frame) {
    if (!_started || _closed) return;
    _pendingFrames.add(frame);
    if (_pendingFrames.length >= session.maxBatchFrames) {
      _flush(session.maxBatchFrames);
    }
  }

  void _flush(int count) {
    if (_pendingFrames.isEmpty) return;
    final amount = count.clamp(1, _pendingFrames.length).toInt();
    final frames = _pendingFrames.sublist(0, amount);
    _pendingFrames.removeRange(0, amount);
    final batch = encoder.buildBatch(session.sessionId, frames);
    _sendTail = _sendTail.then((_) async {
      try {
        await socket.sendBatch(batch);
        try {
          onBatchSent?.call(batch);
        } on Object {
          // A debug observer must never interrupt landmark streaming.
        }
      } on Object catch (error, stackTrace) {
        _reportError(error, stackTrace);
      }
    });
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _frameSubscription?.cancel();
    _frameSubscription = null;
    try {
      await tracking.stop();
    } finally {
      _flush(_pendingFrames.length);
      await _sendTail;
      if (!socket.isClosed) {
        try {
          await socket.pause();
        } on Object catch (error, stackTrace) {
          _reportError(error, stackTrace);
        }
      }
    }
  }

  Future<void> end() async {
    if (_closed) return;
    await stop();
    try {
      await socket.end();
    } on Object {
      try {
        await sessionClient.deleteSession(session);
      } on Object {
        // Preserve the stream error; the session will expire server-side.
      }
      rethrow;
    } finally {
      sessionClient.close();
      _closed = true;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await stop();
    try {
      await socket.close();
    } finally {
      try {
        await sessionClient.deleteSession(session);
      } on Object catch (error, stackTrace) {
        _reportError(error, stackTrace);
      }
      sessionClient.close();
      _closed = true;
    }
  }

  void _reportError(Object error, [StackTrace? stackTrace]) {
    onError?.call(error, stackTrace ?? StackTrace.current);
  }

  void _checkOpen() {
    if (_closed) throw StateError('The landmark stream integration is closed.');
  }
}
