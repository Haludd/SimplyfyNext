import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser tracker cannot enable the legacy image-upload endpoint', () {
    final source = File('web/hand_tracking.js').readAsStringSync();

    expect(source, contains("const DEEPFACE_API_URL = '';"));
    expect(source, isNot(contains('signBridgeEnableBackend')));
    expect(source, isNot(contains('deepface_api')));
    expect(source, isNot(contains('/v1/emotions/analyze')));
  });

  test('obsolete hypotheses plus features HTTP client is absent', () {
    expect(File('lib/services/api_client.dart').existsSync(), isFalse);
  });
}
