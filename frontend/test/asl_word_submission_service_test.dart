import 'dart:convert';

import 'package:apptesting/models/asl_recognition_models.dart';
import 'package:apptesting/services/asl_word_submission_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('submits only the recognized word contract to the backend', () async {
    Map<String, dynamic>? sent;
    final service = AslWordSubmissionService(
      endpoint: Uri.parse('http://localhost:8000/v1/recognized-signs'),
      client: MockClient((request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'status': 'accepted',
            'caption': 'hello',
            'tts_text': 'hello',
          }),
          202,
        );
      }),
    );
    addTearDown(service.close);

    final receipt = await service.submit(
      eventId: 'asl-1',
      sessionId: 'session-1',
      language: 'asl',
      result: const AslRecognitionResult(
        status: 'recognized',
        word: 'hello',
        confidence: .81,
        modelVersion: 'google_asl_25_v20250723_042752',
        frameCount: 16,
        alternatives: <AslRecognitionCandidate>[
          AslRecognitionCandidate(word: 'hello', confidence: .81, rank: 1),
          AslRecognitionCandidate(word: 'please', confidence: .12, rank: 2),
        ],
      ),
      startedAt: DateTime.utc(2026, 9, 10, 12),
      endedAt: DateTime.utc(2026, 9, 10, 12, 0, 1),
    );

    expect(receipt?.status, 'accepted');
    expect(sent?['word'], 'hello');
    expect(sent?['language'], 'ASL');
    expect(sent?['source'], <String, String>{
      'classifier_id': 'google_asl_25',
      'model_version': 'google_asl_25_v20250723_042752',
      'execution': 'browser_local',
    });
    expect(sent, isNot(contains('frames')));
    expect(sent, isNot(contains('landmarks')));
    expect(sent, isNot(contains('feature_vector')));
  });

  test(
    'does not make a request if a word endpoint is not configured',
    () async {
      final service = AslWordSubmissionService(
        client: MockClient((_) async => throw StateError('must not be called')),
      );
      addTearDown(service.close);

      final receipt = await service.submit(
        eventId: 'asl-1',
        sessionId: 'session-1',
        language: 'ASL',
        result: const AslRecognitionResult(
          status: 'recognized',
          word: 'hello',
          confidence: .81,
          modelVersion: 'google_asl_25_v20250723_042752',
          frameCount: 16,
        ),
        startedAt: DateTime.utc(2026, 9, 10),
        endedAt: DateTime.utc(2026, 9, 10),
      );

      expect(receipt, isNull);
    },
  );
}
