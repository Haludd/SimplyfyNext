/// A browser-local temporal ASL model result.
///
/// Landmark frames and camera images are intentionally absent. This is the
/// compact result that may cross the frontend/backend boundary.
final class AslRecognitionResult {
  const AslRecognitionResult({
    required this.status,
    required this.confidence,
    required this.modelVersion,
    required this.frameCount,
    this.word,
    this.reason,
    this.detail,
    this.alternatives = const <AslRecognitionCandidate>[],
    this.startedAtMs,
    this.endedAtMs,
    this.inferenceMs,
  });

  final String status;
  final String? word;
  final double confidence;
  final String modelVersion;
  final int frameCount;
  final String? reason;
  final String? detail;
  final List<AslRecognitionCandidate> alternatives;
  final int? startedAtMs;
  final int? endedAtMs;
  final int? inferenceMs;

  bool get isRecognized =>
      status == 'recognized' && word?.trim().isNotEmpty == true;

  factory AslRecognitionResult.fromJson(Map<String, dynamic> json) {
    final rawAlternatives = json['alternatives'];
    return AslRecognitionResult(
      status: json['status'] as String? ?? 'unavailable',
      word: _nonEmpty(json['word']),
      confidence: _number(json['confidence']),
      modelVersion: json['model_version'] as String? ?? '',
      frameCount: _integer(json['frame_count']),
      reason: _nonEmpty(json['reason']),
      detail: _nonEmpty(json['detail']),
      alternatives: rawAlternatives is List
          ? rawAlternatives
                .whereType<Map>()
                .map(
                  (candidate) => AslRecognitionCandidate.fromJson(
                    Map<String, dynamic>.from(candidate),
                  ),
                )
                .toList(growable: false)
          : const <AslRecognitionCandidate>[],
      startedAtMs: _optionalInteger(json['started_at_ms']),
      endedAtMs: _optionalInteger(json['ended_at_ms']),
      inferenceMs: _optionalInteger(json['inference_ms']),
    );
  }
}

/// Receipt for an explicit, browser-local correction of the most recent ASL
/// motion capture. It contains neither camera data nor landmarks.
final class AslPersonalTemplateReceipt {
  const AslPersonalTemplateReceipt({
    required this.status,
    required this.sampleCount,
    this.label,
  });

  final String status;
  final int sampleCount;
  final String? label;

  bool get isStored => status == 'stored';

  factory AslPersonalTemplateReceipt.fromJson(Map<String, dynamic> json) =>
      AslPersonalTemplateReceipt(
        status: json['status'] as String? ?? 'unavailable',
        sampleCount: _integer(json['sample_count']),
        label: _nonEmpty(json['label']),
      );
}

final class AslRecognitionCandidate {
  const AslRecognitionCandidate({
    required this.word,
    required this.confidence,
    required this.rank,
  });

  final String word;
  final double confidence;
  final int rank;

  factory AslRecognitionCandidate.fromJson(Map<String, dynamic> json) =>
      AslRecognitionCandidate(
        word: json['word'] as String? ?? 'unknown',
        confidence: _number(json['confidence']),
        rank: _integer(json['rank']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'word': word,
    'confidence': confidence,
    'rank': rank,
  };
}

double _number(Object? value) => (value as num?)?.toDouble() ?? 0;
int _integer(Object? value) => (value as num?)?.toInt() ?? 0;
int? _optionalInteger(Object? value) => value is num ? value.toInt() : null;
String? _nonEmpty(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
