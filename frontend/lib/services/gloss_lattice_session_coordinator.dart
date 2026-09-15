import '../contracts/gloss_lattice.dart';

typedef ElapsedMillisecondsReader = int Function();

/// Owns the monotonic clock origin and ordered counters for one lattice
/// session.
///
/// Create this immediately before `POST /v1/sessions`. Keep the same instance
/// until the session ends. A retransmission reuses its already-built lattice;
/// it must not ask this coordinator for another sequence number.
final class GlossLatticeSessionCoordinator {
  factory GlossLatticeSessionCoordinator.start() {
    final wallClockOrigin = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    return GlossLatticeSessionCoordinator.withClock(
      readElapsedMilliseconds: () => stopwatch.elapsedMilliseconds,
      wallClockOrigin: wallClockOrigin,
    );
  }

  factory GlossLatticeSessionCoordinator.withClock({
    required ElapsedMillisecondsReader readElapsedMilliseconds,
    DateTime? wallClockOrigin,
    int initialLatticeSeq = 0,
    int initialControlSeq = 0,
  }) => GlossLatticeSessionCoordinator._(
    readElapsedMilliseconds,
    _validateInitialSequence(initialLatticeSeq, 'initialLatticeSeq'),
    _validateInitialSequence(initialControlSeq, 'initialControlSeq'),
    wallClockOrigin?.toUtc(),
  );

  GlossLatticeSessionCoordinator._(
    this._readElapsedMilliseconds,
    this._nextLatticeSeq,
    this._nextControlSeq,
    this._wallClockOrigin,
  );

  final ElapsedMillisecondsReader _readElapsedMilliseconds;
  int _nextLatticeSeq;
  int _nextControlSeq;
  final DateTime? _wallClockOrigin;
  bool _latticeSequenceExhausted = false;
  bool _controlSequenceExhausted = false;
  int _lastElapsedMilliseconds = -1;

  /// Elapsed milliseconds from this session's one monotonic clock origin.
  int nowMs() {
    final value = _readElapsedMilliseconds();
    if (value < 0 || value > GlossLatticeContract.maxSafeJsonInteger) {
      throw StateError(
        'The session clock must return a safe non-negative integer.',
      );
    }
    if (value < _lastElapsedMilliseconds) {
      throw StateError('The session monotonic clock moved backwards.');
    }
    _lastElapsedMilliseconds = value;
    return value;
  }

  /// Maps Harold's capture-time [DateTime] onto this session's monotonic
  /// millisecond origin. Custom-clock tests without a wall-clock origin fall
  /// back to [nowMs].
  int captureTimestampMs(DateTime capturedAt) {
    final origin = _wallClockOrigin;
    if (origin == null) return nowMs();
    final value = capturedAt.toUtc().difference(origin).inMilliseconds;
    if (value < 0 || value > GlossLatticeContract.maxSafeJsonInteger) {
      throw StateError(
        'The frame capture timestamp is outside this session timebase.',
      );
    }
    return value;
  }

  /// Allocates the next sequence for a new immutable lattice.
  int nextLatticeSeq() {
    if (_latticeSequenceExhausted) {
      throw StateError(
        'lattice_seq has reached the maximum safe JSON integer.',
      );
    }
    final value = _nextLatticeSeq;
    if (value == GlossLatticeContract.maxSafeJsonInteger) {
      _latticeSequenceExhausted = true;
    } else {
      _nextLatticeSeq = value + 1;
    }
    return value;
  }

  /// Allocates the next sequence for a future `ping` or `end` control.
  int nextControlSeq() {
    if (_controlSequenceExhausted) {
      throw StateError(
        'control_seq has reached the maximum safe JSON integer.',
      );
    }
    final value = _nextControlSeq;
    if (value == GlossLatticeContract.maxSafeJsonInteger) {
      _controlSequenceExhausted = true;
    } else {
      _nextControlSeq = value + 1;
    }
    return value;
  }
}

int _validateInitialSequence(int value, String name) {
  if (value < 0 || value > GlossLatticeContract.maxSafeJsonInteger) {
    throw ArgumentError.value(
      value,
      name,
      'must be a safe non-negative integer',
    );
  }
  return value;
}
