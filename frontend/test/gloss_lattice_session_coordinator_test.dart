import 'package:apptesting/contracts/gloss_lattice.dart';
import 'package:apptesting/services/gloss_lattice_session_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('returns exact non-decreasing session-relative milliseconds', () {
    final values = <int>[0, 33, 33, 71].iterator;
    final coordinator = GlossLatticeSessionCoordinator.withClock(
      readElapsedMilliseconds: () {
        values.moveNext();
        return values.current;
      },
    );

    expect(
      <int>[
        coordinator.nowMs(),
        coordinator.nowMs(),
        coordinator.nowMs(),
        coordinator.nowMs(),
      ],
      <int>[0, 33, 33, 71],
    );
  });

  test('rejects a clock that moves backwards', () {
    final values = <int>[100, 99].iterator;
    final coordinator = GlossLatticeSessionCoordinator.withClock(
      readElapsedMilliseconds: () {
        values.moveNext();
        return values.current;
      },
    );

    expect(coordinator.nowMs(), 100);
    expect(coordinator.nowMs, throwsStateError);
  });

  test('maps a capture DateTime to the session-monotonic origin', () {
    final origin = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final coordinator = GlossLatticeSessionCoordinator.withClock(
      readElapsedMilliseconds: () => 500,
      wallClockOrigin: origin,
    );

    expect(
      coordinator.captureTimestampMs(
        origin.add(const Duration(milliseconds: 123)),
      ),
      123,
    );
    expect(
      () => coordinator.captureTimestampMs(
        origin.subtract(const Duration(milliseconds: 1)),
      ),
      throwsStateError,
    );
  });

  test('rejects negative and unsafe clock values', () {
    final negative = GlossLatticeSessionCoordinator.withClock(
      readElapsedMilliseconds: () => -1,
    );
    final unsafe = GlossLatticeSessionCoordinator.withClock(
      readElapsedMilliseconds: () =>
          GlossLatticeContract.maxSafeJsonInteger + 1,
    );

    expect(negative.nowMs, throwsStateError);
    expect(unsafe.nowMs, throwsStateError);
  });

  test('allocates lattice and control sequences independently from zero', () {
    final coordinator = GlossLatticeSessionCoordinator.withClock(
      readElapsedMilliseconds: () => 0,
    );

    expect(coordinator.nextLatticeSeq(), 0);
    expect(coordinator.nextLatticeSeq(), 1);
    expect(coordinator.nextControlSeq(), 0);
    expect(coordinator.nextLatticeSeq(), 2);
    expect(coordinator.nextControlSeq(), 1);
  });

  test('supports explicit resume sequence values', () {
    final coordinator = GlossLatticeSessionCoordinator.withClock(
      readElapsedMilliseconds: () => 0,
      initialLatticeSeq: 7,
      initialControlSeq: 11,
    );

    expect(coordinator.nextLatticeSeq(), 7);
    expect(coordinator.nextControlSeq(), 11);
  });

  test('allows the maximum safe sequence exactly once', () {
    final maximum = GlossLatticeContract.maxSafeJsonInteger;
    final coordinator = GlossLatticeSessionCoordinator.withClock(
      readElapsedMilliseconds: () => 0,
      initialLatticeSeq: maximum,
      initialControlSeq: maximum,
    );

    expect(coordinator.nextLatticeSeq(), maximum);
    expect(coordinator.nextControlSeq(), maximum);
    expect(coordinator.nextLatticeSeq, throwsStateError);
    expect(coordinator.nextControlSeq, throwsStateError);
  });

  test('rejects invalid initial sequences', () {
    expect(
      () => GlossLatticeSessionCoordinator.withClock(
        readElapsedMilliseconds: () => 0,
        initialLatticeSeq: -1,
      ),
      throwsArgumentError,
    );
    expect(
      () => GlossLatticeSessionCoordinator.withClock(
        readElapsedMilliseconds: () => 0,
        initialControlSeq: GlossLatticeContract.maxSafeJsonInteger + 1,
      ),
      throwsArgumentError,
    );
  });

  test('default Stopwatch clock starts with a safe monotonic value', () {
    final coordinator = GlossLatticeSessionCoordinator.start();
    final first = coordinator.nowMs();
    final second = coordinator.nowMs();

    expect(first, greaterThanOrEqualTo(0));
    expect(second, greaterThanOrEqualTo(first));
  });
}
