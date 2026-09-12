import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/asl_recognition_models.dart';

/// Posts a browser-recognized word to the backend without uploading camera
/// frames, MediaPipe landmarks, or feature windows.
final class AslWordSubmissionService {
  AslWordSubmissionService({
    this.endpoint,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null {
    if (endpoint != null &&
        (!endpoint!.isAbsolute ||
            endpoint!.host.isEmpty ||
            (endpoint!.scheme != 'http' && endpoint!.scheme != 'https'))) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'must be an absolute http or https URL',
      );
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be positive',
      );
    }
  }

  factory AslWordSubmissionService.fromEnvironment({http.Client? client}) {
    const configured = String.fromEnvironment('SIGNBRIDGE_WORD_SUBMISSION_URL');
    final text = configured.trim();
    return AslWordSubmissionService(
      endpoint: text.isEmpty ? null : Uri.parse(text),
      client: client,
    );
  }

  final Uri? endpoint;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  bool _closed = false;

  bool get isConfigured => endpoint != null;

  Future<AslWordSubmissionReceipt?> submit({
    required String eventId,
    required String sessionId,
    required String language,
    required AslRecognitionResult result,
    required DateTime startedAt,
    required DateTime endedAt,
  }) async {
    if (_closed) throw StateError('AslWordSubmissionService is closed.');
    final target = endpoint;
    if (target == null) return null;
    if (!result.isRecognized) {
      throw ArgumentError.value(
        result,
        'result',
        'must contain a recognized word',
      );
    }

    late http.Response response;
    try {
      response = await _client
          .post(
            target,
            headers: const <String, String>{
              'accept': 'application/json',
              'content-type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'schema_version': 'signbridge.recognized-word.v1',
              'event_id': eventId,
              'session_id': sessionId,
              'language': language.toUpperCase(),
              'word': result.word,
              'confidence': result.confidence,
              'source': <String, String>{
                'classifier_id': 'google_asl_25',
                'model_version': result.modelVersion,
                'execution': 'browser_local',
              },
              'started_at': startedAt.toUtc().toIso8601String(),
              'ended_at': endedAt.toUtc().toIso8601String(),
              'alternatives': result.alternatives
                  .map((candidate) => candidate.toJson())
                  .toList(growable: false),
            }),
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw const AslWordSubmissionException(
        'The word-processing backend did not respond in time.',
      );
    } on Object {
      throw const AslWordSubmissionException(
        'The word-processing backend could not be reached.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AslWordSubmissionException(
        'The word-processing backend rejected the result '
        '(HTTP ${response.statusCode}).',
      );
    }
    if (response.bodyBytes.length > 64 * 1024) {
      throw const AslWordSubmissionException(
        'The word-processing backend returned an oversized response.',
      );
    }

    Map<String, dynamic> payload = const <String, dynamic>{};
    if (response.bodyBytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map) payload = Map<String, dynamic>.from(decoded);
      } on Object {
        throw const AslWordSubmissionException(
          'The word-processing backend returned invalid JSON.',
        );
      }
    }
    return AslWordSubmissionReceipt.fromJson(payload);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }
}

final class AslWordSubmissionReceipt {
  const AslWordSubmissionReceipt({
    required this.status,
    this.caption,
    this.ttsText,
  });

  final String status;
  final String? caption;
  final String? ttsText;

  factory AslWordSubmissionReceipt.fromJson(Map<String, dynamic> json) =>
      AslWordSubmissionReceipt(
        status: json['status'] as String? ?? 'accepted',
        caption: _optionalText(json['caption']),
        ttsText: _optionalText(json['tts_text']),
      );
}

final class AslWordSubmissionException implements Exception {
  const AslWordSubmissionException(this.message);

  final String message;

  @override
  String toString() => 'AslWordSubmissionException: $message';
}

String? _optionalText(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
