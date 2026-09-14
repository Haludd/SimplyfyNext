import 'package:apptesting/models/tracking_models.dart';
import 'package:apptesting/services/personal_sign_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const matcher = PersonalSignMatcher();

  test(
    'matches a recorded personal sign across a different capture length',
    () {
      final recording = _sequence(10, offset: .10);
      final sign = _sign('kopi', recording);

      final match = matcher.match(
        sequence: _sequence(24, offset: .10),
        signs: <CustomSign>[sign],
        language: 'SgSL',
      );

      expect(match, isNotNull);
      expect(match!.label, 'kopi');
      expect(match.confidence, closeTo(1, 1e-12));
      expect(match.sampleCount, 5);
    },
  );

  test('matches an ordinary variation of a saved personal sign', () {
    final sign = _sign('kopi', _sequence(12, offset: .10));

    final match = matcher.match(
      sequence: _sequence(18, offset: .24),
      signs: <CustomSign>[sign],
      language: 'SgSL',
    );

    expect(match, isNotNull);
    expect(match!.label, 'kopi');
    expect(match.confidence, greaterThanOrEqualTo(.55));
  });

  test('does not match a different language or a distant movement', () {
    final sign = _sign('kopi', _sequence(10, offset: .10));

    expect(
      matcher.match(
        sequence: _sequence(12, offset: .70),
        signs: <CustomSign>[sign],
        language: 'SgSL',
      ),
      isNull,
    );
    expect(
      matcher.match(
        sequence: _sequence(12, offset: .10),
        signs: <CustomSign>[sign],
        language: 'ASL',
      ),
      isNull,
    );
  });

  test('does not claim a result when two templates are too similar', () {
    final sequence = _sequence(12, offset: .10);
    final first = _sign('first', sequence);
    final second = _sign('second', sequence);

    expect(
      matcher.match(
        sequence: sequence,
        signs: <CustomSign>[first, second],
        language: 'SgSL',
      ),
      isNull,
    );
  });

  test('keeps legacy snapshots usable as one-frame templates', () {
    final legacy = CustomSign(
      label: 'home',
      samples: <List<double>>[
        for (var index = 0; index < 5; index += 1) _frame(.2),
      ],
      createdAt: DateTime.utc(2026),
      language: 'ASL',
    );

    expect(legacy.sampleCount, 5);
    expect(legacy.templateSequences, hasLength(5));
    expect(
      matcher
          .match(
            sequence: <List<double>>[_frame(.2), _frame(.2)],
            signs: <CustomSign>[legacy],
            language: 'ASL',
          )
          ?.label,
      'home',
    );
  });
}

CustomSign _sign(String label, List<List<double>> recording) => CustomSign(
  label: label,
  samples: <List<double>>[
    for (var index = 0; index < 5; index += 1) recording[recording.length ~/ 2],
  ],
  sequences: <List<List<double>>>[
    for (var index = 0; index < 5; index += 1) recording,
  ],
  createdAt: DateTime.utc(2026),
  language: 'SgSL',
  vectorSize: 170,
);

List<List<double>> _sequence(int length, {required double offset}) =>
    List<List<double>>.generate(
      length,
      (frame) => _frame(offset + frame / (length - 1) * .04),
      growable: false,
    );

List<double> _frame(double value) => List<double>.generate(
  170,
  (index) => value + (index % 3) * .01,
  growable: false,
);
