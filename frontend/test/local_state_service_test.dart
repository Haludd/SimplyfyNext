import 'dart:convert';

import 'package:apptesting/models/tracking_models.dart';
import 'package:apptesting/services/local_state_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('exports and decodes a portable personal-sign backup', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final service = LocalStateService(preferences);
    final sign = CustomSign(
      label: 'Mum',
      language: 'ASL',
      createdAt: DateTime.utc(2026, 9, 17),
      sequences: List<List<List<double>>>.generate(
        5,
        (_) => <List<double>>[
          <double>[.1, .2, .3],
        ],
      ),
      samples: List<List<double>>.generate(5, (_) => <double>[.1, .2, .3]),
    );

    final backup = service.exportCustomSignsBackup(<CustomSign>[sign]);
    final decoded = jsonDecode(backup) as Map<String, dynamic>;
    final restored = service.decodeCustomSignsBackup(backup);

    expect(decoded['type'], 'signbridge_personal_sign_backup');
    expect(decoded['schema_version'], 1);
    expect(restored, hasLength(1));
    expect(restored.single.label, 'Mum');
    expect(restored.single.sampleCount, 5);
  });

  test('rejects an incompatible personal-sign backup', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = await SharedPreferences.getInstance();
    final service = LocalStateService(preferences);

    expect(
      () => service.decodeCustomSignsBackup('{"type":"wrong"}'),
      throwsFormatException,
    );
  });
}
