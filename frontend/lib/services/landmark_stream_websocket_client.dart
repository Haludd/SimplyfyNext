import 'dart:async';
import 'dart:convert';

import 'gloss_lattice_websocket_client.dart';
import '../contracts/landmark_stream.dart';

final class LandmarkStreamProtocolException implements Exception {
  const LandmarkStreamProtocolException({
    required this.code,
    required this.message,
    this.retryable = false,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() =>
      'LandmarkStreamProtocolException($code, retryable: $retryable): '
      '$message';
}

final class LandmarkStreamBatchAcknowledgement {
  LandmarkStreamBatchAcknowledgement(Map<String, dynamic> event)
    : event = Map<String, dynamic>.unmodifiable(event),
      batchSeq = _requiredInt(event, 'batch_seq'),
      lastFrameSeq = _requiredInt(event, 'last_frame_seq'),
      receivedFrames = _requiredInt(event, 'received_frames'),
      bufferedFrames = _requiredInt(event, 'buffered_frames'),
      droppedFrames = _requiredInt(event, 'dropped_frames');

  final Map<String, dynamic> event;
  final int batchSeq;
  final int lastFrameSeq;
  final int receivedFrames;
  final int bufferedFrames;
  final int droppedFrames;
}

/// Client for the backend-owned normalisation, segmentation, and classifier.
///
/// Unlike the GlossLattice client, this socket sends `landmark_batch` messages
/// and keeps the server's result events flowing to [onEvent].
final class LandmarkStreamWebSocketClient {
  LandmarkStreamWebSocketClient({
    required GlossLatticeTextChannel channel,
    required this.sessionId,
    this.responseTimeout = const Duration(seconds: 60),
    this.onEvent,
  }) : _channel = channel {
    if (sessionId.trim().isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must not be empty');
    }
    if (responseTimeout <= Duration.zero) {
      throw ArgumentError.value(
        responseTimeout,
        'responseTimeout',
        'must be positive',
      );
    }
    _streamSubscription = channel.stream.listen(
      _acceptMessage,
      onError: _acceptError,
      onDone: _acceptDone,
      cancelOnError: false,
    );
  }

  final GlossLatticeTextChannel _channel;
  final String sessionId;
  final Duration responseTimeout;
  final void Function(Map<String, dynamic> event)? onEvent;
  final List<Map<String, dynamic>> _queuedEvents = <Map<String, dynamic>>[];
  final List<_EventWaiter> _waiters = <_EventWaiter>[];
  final Completer<void> _closedCompleter = Completer<void>();
  late final StreamSubscription<dynamic> _streamSubscription;
  Object? _streamError;
  StackTrace? _streamStackTrace;
  int _nextControlSeq = 0;
  bool _closed = false;
  bool _initialIdleReceived = false;
  bool _operationInProgress = false;

  bool get isClosed => _closed;

  Future<void> waitForInitialIdle() async {
    if (_closed) _throwClosed();
    if (_initialIdleReceived) return;
    while (true) {
      final event = await _nextEvent();
      switch (event['type']) {
        case 'activity':
          if (event['state'] == 'idle') {
            _initialIdleReceived = true;
            return;
          }
          if (event['state'] == 'signing' ||
              event['state'] == 'processing') {
            continue;
          }
          throw const LandmarkStreamProtocolException(
            code: 'invalid_response',
            message: 'The backend sent an invalid activity state.',
          );
        case 'error':
          throw _serverError(event);
        default:
          throw LandmarkStreamProtocolException(
            code: 'invalid_response',
            message:
                'Expected initial activity idle, received "${event['type']}".',
          );
      }
    }
  }

  Future<LandmarkStreamBatchAcknowledgement> sendBatch(
    LandmarkBatch batch,
  ) async {
    _checkCanOperate();
    if (batch.sessionId != sessionId) {
      throw const LandmarkStreamProtocolException(
        code: 'session_mismatch',
        message: 'The batch session_id does not match this socket.',
      );
    }
    if (!_initialIdleReceived) await waitForInitialIdle();
    await _beginOperation();
    try {
      _channel.sendText(batch.toWireJson());
      final event = await _waitFor((candidate) {
        if (candidate['type'] == 'error') return true;
        return candidate['type'] == 'ack' &&
            candidate['batch_seq'] == batch.batchSeq;
      });
      if (event['type'] == 'error') throw _serverError(event);
      return LandmarkStreamBatchAcknowledgement(event);
    } finally {
      _operationInProgress = false;
    }
  }

  Future<Map<String, dynamic>> ping({int? clientMs}) async {
    final controlSeq = _nextControlSeq++;
    return _sendControlAndWait(
      landmarkStreamControl(
        sessionId: sessionId,
        controlSeq: controlSeq,
        action: 'ping',
        clientMs: clientMs,
      ),
      (event) =>
          event['type'] == 'pong' && event['control_seq'] == controlSeq,
    );
  }

  Future<void> start() => _sendControl(
    landmarkStreamControl(
      sessionId: sessionId,
      controlSeq: _nextControlSeq++,
      action: 'start',
    ),
  );

  Future<void> pause() => _sendControl(
    landmarkStreamControl(
      sessionId: sessionId,
      controlSeq: _nextControlSeq++,
      action: 'pause',
    ),
  );

  Future<void> resume() => _sendControl(
    landmarkStreamControl(
      sessionId: sessionId,
      controlSeq: _nextControlSeq++,
      action: 'resume',
    ),
  );

  Future<void> commit() => _sendControl(
    landmarkStreamControl(
      sessionId: sessionId,
      controlSeq: _nextControlSeq++,
      action: 'commit',
    ),
  );

  Future<void> end() async {
    if (_closed) return;
    final control = landmarkStreamControl(
      sessionId: sessionId,
      controlSeq: _nextControlSeq++,
      action: 'end',
    );
    await _beginOperation();
    try {
      _channel.sendText(jsonEncode(control));
      await _closedCompleter.future.timeout(responseTimeout);
    } on TimeoutException {
      await close();
      throw const LandmarkStreamProtocolException(
        code: 'end_timeout',
        message: 'The backend did not close the landmark stream in time.',
        retryable: true,
      );
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> _sendControl(Map<String, dynamic> control) async {
    await _sendControlAndWait(control, (event) {
      if (event['type'] == 'error') return true;
      if (event['type'] != 'activity') return false;
      final state = event['state'];
      return state == 'idle' || state == 'signing' || state == 'processing';
    });
  }

  Future<Map<String, dynamic>> _sendControlAndWait(
    Map<String, dynamic> control,
    bool Function(Map<String, dynamic>) matches,
  ) async {
    _checkCanOperate();
    if (!_initialIdleReceived) await waitForInitialIdle();
    await _beginOperation();
    try {
      _channel.sendText(jsonEncode(control));
      final event = await _waitFor(matches);
      if (event['type'] == 'error') throw _serverError(event);
      return event;
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> _beginOperation() async {
    if (_operationInProgress) {
      throw StateError('Only one landmark stream operation may be in flight.');
    }
    _operationInProgress = true;
  }

  Future<Map<String, dynamic>> _nextEvent() {
    if (_queuedEvents.isNotEmpty) {
      return Future<Map<String, dynamic>>.value(_queuedEvents.removeAt(0));
    }
    if (_streamError != null) {
      return Future<Map<String, dynamic>>.error(
        _streamError!,
        _streamStackTrace ?? StackTrace.current,
      );
    }
    if (_closed) _throwClosed();
    final waiter = _EventWaiter((_) => true);
    _waiters.add(waiter);
    return waiter.future.timeout(responseTimeout);
  }

  Future<Map<String, dynamic>> _waitFor(
    bool Function(Map<String, dynamic>) matches,
  ) async {
    for (var index = 0; index < _queuedEvents.length; index += 1) {
      final event = _queuedEvents[index];
      if (matches(event)) {
        _queuedEvents.removeAt(index);
        return event;
      }
    }
    if (_streamError != null) {
      return Future<Map<String, dynamic>>.error(
        _streamError!,
        _streamStackTrace ?? StackTrace.current,
      );
    }
    if (_closed) _throwClosed();
    final waiter = _EventWaiter(matches);
    _waiters.add(waiter);
    try {
      return await waiter.future.timeout(responseTimeout);
    } on TimeoutException {
      _waiters.remove(waiter);
      throw const LandmarkStreamProtocolException(
        code: 'response_timeout',
        message: 'The backend did not respond within the configured timeout.',
        retryable: true,
      );
    }
  }

  void _acceptMessage(dynamic raw) {
    if (_closed) return;
    if (raw is! String) {
      _acceptError(
        const LandmarkStreamProtocolException(
          code: 'invalid_response',
          message: 'The backend sent a non-text WebSocket message.',
        ),
      );
      return;
    }
    late Object decoded;
    try {
      decoded = jsonDecode(raw);
    } on Object {
      _acceptError(
        const LandmarkStreamProtocolException(
          code: 'invalid_response',
          message: 'The backend sent invalid JSON.',
        ),
      );
      return;
    }
    if (decoded is! Map || decoded.keys.any((Object? key) => key is! String)) {
      _acceptError(
        const LandmarkStreamProtocolException(
          code: 'invalid_response',
          message: 'The backend event must be a JSON object.',
        ),
      );
      return;
    }
    final event = Map<String, dynamic>.from(decoded);
    final type = event['type'];
    if (type is! String) {
      _acceptError(
        const LandmarkStreamProtocolException(
          code: 'invalid_response',
          message: 'The backend event is missing a string type.',
        ),
      );
      return;
    }
    try {
      onEvent?.call(Map<String, dynamic>.unmodifiable(event));
    } on Object {
      // UI observers must not be able to terminate the transport pump.
    }
    for (var index = 0; index < _waiters.length; index += 1) {
      final waiter = _waiters[index];
      if (waiter.matches(event)) {
        _waiters.removeAt(index);
        waiter.complete(event);
        return;
      }
    }
    _queuedEvents.add(event);
    if (_queuedEvents.length > 128) _queuedEvents.removeAt(0);
  }

  void _acceptError(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _streamError ??= error;
    _streamStackTrace ??= stackTrace;
    for (final waiter in List<_EventWaiter>.from(_waiters)) {
      waiter.completeError(error, stackTrace ?? StackTrace.current);
    }
    _waiters.clear();
  }

  void _acceptDone() {
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
    if (!_closed) {
      _closed = true;
      final error = _streamError;
      for (final waiter in List<_EventWaiter>.from(_waiters)) {
        if (error != null) {
          waiter.completeError(
            error,
            _streamStackTrace ?? StackTrace.current,
          );
        } else {
          waiter.completeError(
            const LandmarkStreamProtocolException(
              code: 'socket_closed',
              message: 'The landmark WebSocket closed unexpectedly.',
              retryable: true,
            ),
            StackTrace.current,
          );
        }
      }
      _waiters.clear();
    }
  }

  LandmarkStreamProtocolException _serverError(Map<String, dynamic> event) =>
      LandmarkStreamProtocolException(
        code: event['code'] as String? ?? 'server_error',
        message: event['message'] as String? ?? 'The backend returned an error.',
        retryable: event['retryable'] == true,
      );

  void _checkCanOperate() {
    if (_closed) _throwClosed();
  }

  Never _throwClosed() => throw StateError('The landmark WebSocket is closed.');

  Future<void> close() async {
    if (_closed && _closedCompleter.isCompleted) return;
    _closed = true;
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
    for (final waiter in List<_EventWaiter>.from(_waiters)) {
      waiter.completeError(
        StateError('The landmark WebSocket was closed.'),
        StackTrace.current,
      );
    }
    _waiters.clear();
    await _streamSubscription.cancel();
    try {
      await _channel.close();
    } on Object {
      // Closing is best effort and idempotent.
    }
  }
}

final class _EventWaiter {
  _EventWaiter(this.matches);

  final bool Function(Map<String, dynamic>) matches;
  final Completer<Map<String, dynamic>> _completer =
      Completer<Map<String, dynamic>>();

  Future<Map<String, dynamic>> get future => _completer.future;

  void complete(Map<String, dynamic> event) {
    if (!_completer.isCompleted) _completer.complete(event);
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }
}

int _requiredInt(Map<String, dynamic> event, String key) {
  final value = event[key];
  if (value is! int || value < 0) {
    throw LandmarkStreamProtocolException(
      code: 'invalid_response',
      message: '$key must be a non-negative integer.',
    );
  }
  return value;
}
