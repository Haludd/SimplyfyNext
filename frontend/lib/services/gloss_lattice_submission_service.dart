import '../adapters/gloss_lattice_builder.dart';
import '../contracts/gloss_lattice.dart';
import '../integration/segmentation_classification_port.dart';
import 'gloss_lattice_session_coordinator.dart';
import 'gloss_lattice_websocket_client.dart';

/// Packages Esther's completed Stage 5/6 output and sends it exactly once.
///
/// A failed submission remains pending so a reconnect can retransmit the
/// exact same `(session_id, lattice_seq)` bytes, as required by the backend's
/// idempotency rules.
final class GlossLatticeSubmissionService {
  GlossLatticeSubmissionService({
    required this.builder,
    required GlossLatticeWebSocketClient websocketClient,
    required this.sessionCoordinator,
  }) : _websocketClient = websocketClient {
    if (builder.sessionId != websocketClient.sessionId) {
      throw ArgumentError(
        'Builder and WebSocket client must use the same session_id.',
      );
    }
  }

  final GlossLatticeBuilder builder;
  final GlossLatticeSessionCoordinator sessionCoordinator;
  GlossLatticeWebSocketClient _websocketClient;

  GlossLattice? _pendingLattice;
  bool _submissionInProgress = false;
  int _maxRetries = 0;
  Future<void> Function()? _reconnect;

  GlossLattice? get pendingLattice => _pendingLattice;
  GlossLatticeWebSocketClient get websocketClient => _websocketClient;

  /// Enables bounded retry for the production composition root.
  ///
  /// The pending lattice is never rebuilt. A retry reconnects the same live
  /// session and resends the exact sequence/content so backend replay remains
  /// idempotent. Tests and local callers can leave this disabled.
  void configureRetry({
    required int maxRetries,
    required Future<void> Function() reconnect,
  }) {
    if (maxRetries < 0 || maxRetries > 5) {
      throw ArgumentError.value(maxRetries, 'maxRetries', 'must be 0 through 5');
    }
    _maxRetries = maxRetries;
    _reconnect = reconnect;
  }

  Future<GlossLatticeSubmissionReceipt> submit(
    ClassifiedUtteranceOutput output,
  ) async {
    if (_pendingLattice != null) {
      throw StateError(
        'Retry the pending lattice before submitting another utterance.',
      );
    }
    final lattice = builder.build(
      latticeSeq: sessionCoordinator.nextLatticeSeq(),
      utteranceId: output.utteranceId,
      startedAtMs: output.startedAtMs,
      endedAtMs: output.endedAtMs,
      slots: output.slots,
    );
    _pendingLattice = lattice;
    return _sendPendingWithRetry();
  }

  Future<GlossLatticeSubmissionReceipt> retryPending() {
    if (_pendingLattice == null) {
      throw StateError('There is no pending lattice to retry.');
    }
    return _sendPendingWithRetry();
  }

  Future<GlossLatticeSubmissionReceipt> _sendPendingWithRetry() async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt <= _maxRetries; attempt += 1) {
      try {
        return await _sendPending();
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        final retryable = error is GlossLatticeWebSocketException &&
            error.retryable;
        if (!retryable || attempt == _maxRetries || _reconnect == null) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        await _reconnect!();
        final delayMs = 200 * (1 << attempt);
        await Future<void>.delayed(
          Duration(milliseconds: delayMs > 2000 ? 2000 : delayMs),
        );
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace ?? StackTrace.current);
  }

  Future<GlossLatticeSubmissionReceipt> _sendPending() async {
    if (_submissionInProgress) {
      throw StateError('A lattice submission is already in progress.');
    }
    final lattice = _pendingLattice!;
    _submissionInProgress = true;
    try {
      final receipt = await _websocketClient.send(lattice);
      _pendingLattice = null;
      return receipt;
    } finally {
      _submissionInProgress = false;
    }
  }

  /// Rebinds this session after a transport disconnect without rebuilding the
  /// pending lattice. A later [retryPending] therefore sends identical bytes
  /// with the original sequence number.
  Future<void> replaceWebsocketClient(
    GlossLatticeWebSocketClient replacement,
  ) async {
    if (_submissionInProgress) {
      throw StateError('Cannot replace the WebSocket during a submission.');
    }
    if (replacement.sessionId != builder.sessionId) {
      throw ArgumentError(
        'Replacement WebSocket client must use the same session_id.',
      );
    }
    final previous = _websocketClient;
    _websocketClient = replacement;
    await previous.close();
  }

  Future<void> close() => _websocketClient.close();
}
