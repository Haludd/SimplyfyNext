import 'dart:convert';
import 'dart:io';

import 'package:apptesting/contracts/translated_sign_utterance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts the backend canonical TranslatedSignUtterance v1 fixture', () {
    final raw = File('../tests/fixtures/translated_sign_utterance_v1.json')
        .readAsStringSync();

    final utterance = TranslatedSignUtterance.fromWireJson(raw);

    expect(utterance.words.map((word) => word.word), <String>[
      'TABLE',
      'TABLE',
    ]);
    expect(utterance.toJson().keys.toSet(), <String>{
      'type',
      'schema_version',
      'message_id',
      'client_sequence',
      'source_language',
      'target_language',
      'is_final',
      'completion_reason',
      'producer',
      'words',
    });
  });

  test('rejects every backend invalid v1 fixture', () {
    final fixtures = jsonDecode(
      File('../tests/fixtures/translated_sign_invalid_v1.json')
          .readAsStringSync(),
    ) as List<dynamic>;

    for (final rawFixture in fixtures) {
      final fixture = Map<String, dynamic>.from(rawFixture as Map);
      final name = fixture['name'] as String;
      expect(
        () {
          if (fixture['raw_json'] case final String raw) {
            TranslatedSignUtterance.fromWireJson(raw);
          } else {
            TranslatedSignUtterance.fromJson(
              Map<String, dynamic>.from(fixture['payload'] as Map),
            );
          }
        },
        throwsA(isA<TranslatedSignUtteranceValidationException>()),
        reason: name,
      );
    }
  });
}
