import 'package:apptesting/models/asl_recognition_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a compact browser recognition result', () {
    final result = AslRecognitionResult.fromJson(<String, dynamic>{
      'status': 'recognized',
      'word': 'hello',
      'confidence': .8125,
      'model_version': 'google_asl_25_v20250723_042752',
      'frame_count': 28,
      'started_at_ms': 1000,
      'ended_at_ms': 1933,
      'inference_ms': 217,
      'alternatives': <Map<String, dynamic>>[
        <String, dynamic>{'word': 'hello', 'confidence': .8125, 'rank': 1},
        <String, dynamic>{'word': 'please', 'confidence': .12, 'rank': 2},
      ],
    });

    expect(result.isRecognized, isTrue);
    expect(result.word, 'hello');
    expect(result.frameCount, 28);
    expect(result.inferenceMs, 217);
    expect(result.alternatives.map((candidate) => candidate.word), <String>[
      'hello',
      'please',
    ]);
  });

  test('does not treat an unknown outcome as a word', () {
    final result = AslRecognitionResult.fromJson(<String, dynamic>{
      'status': 'unknown',
      'confidence': .42,
      'model_version': 'google_asl_25_v20250723_042752',
      'frame_count': 16,
      'reason': 'low_confidence',
    });

    expect(result.isRecognized, isFalse);
    expect(result.word, isNull);
    expect(result.reason, 'low_confidence');
  });

  test('parses a browser-local personal correction receipt', () {
    final receipt = AslPersonalTemplateReceipt.fromJson(<String, dynamic>{
      'status': 'stored',
      'label': 'bye',
      'sample_count': 2,
    });

    expect(receipt.isStored, isTrue);
    expect(receipt.label, 'bye');
    expect(receipt.sampleCount, 2);
  });
}
