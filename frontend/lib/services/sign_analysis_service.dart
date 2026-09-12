import '../models/tracking_models.dart';

class SignLexiconEntry {
  const SignLexiconEntry({
    required this.id,
    required this.label,
    required this.language,
    required this.sourceUrl,
    required this.parameters,
  });

  final String id;
  final String label;
  final String language;
  final String sourceUrl;
  final List<String> parameters;
}

class SignLanguageProfile {
  const SignLanguageProfile({
    required this.code,
    required this.name,
    required this.sourceUrl,
    required this.sourceType,
    required this.note,
  });

  final String code;
  final String name;
  final String sourceUrl;
  final String sourceType;
  final String note;
}

class SignLexicon {
  static const version = '2026-09-seed-2';

  static const profiles = <SignLanguageProfile>[
    SignLanguageProfile(
      code: 'ASL',
      name: 'American Sign Language',
      sourceUrl: 'https://www.handspeak.com/word/',
      sourceType: 'dictionary_reference',
      note: 'Reference labels and sign-feature fields; not a training export.',
    ),
    SignLanguageProfile(
      code: 'BSL',
      name: 'British Sign Language',
      sourceUrl: 'https://bslsignbank.ucl.ac.uk/about/dictionary/',
      sourceType: 'dictionary_reference',
      note: 'Use the SignBank licensing/access terms before importing data.',
    ),
    SignLanguageProfile(
      code: 'SgSL',
      name: 'Singapore Sign Language',
      sourceUrl: 'https://sadeaf.org.sg/faq-on-sadeaf-and-about-the-deaf-and-hard-of-hearing/faq-on-singapore-sign-language/',
      sourceType: 'community_reference',
      note: 'SgSL data needs community-approved and consented examples.',
    ),
  ];

  static const entries = <SignLexiconEntry>[
    SignLexiconEntry(
      id: 'hello',
      label: 'Hello',
      language: 'ASL',
      sourceUrl: 'https://www.handspeak.com/word/hello/',
      parameters: <String>['handshape', 'movement', 'location', 'handedness'],
    ),
    SignLexiconEntry(
      id: 'help',
      label: 'Help',
      language: 'ASL',
      sourceUrl: 'https://www.handspeak.com/word/help/',
      parameters: <String>['handshape', 'movement', 'location'],
    ),
    SignLexiconEntry(
      id: 'water',
      label: 'Water',
      language: 'ASL',
      sourceUrl: 'https://www.handspeak.com/word/water/',
      parameters: <String>['handshape', 'movement', 'location'],
    ),
    SignLexiconEntry(
      id: 'please',
      label: 'Please',
      language: 'ASL',
      sourceUrl: 'https://www.handspeak.com/word/please/',
      parameters: <String>['handshape', 'movement', 'location'],
    ),
  ];

  static List<SignLexiconEntry> entriesFor(String language) => entries
      .where((entry) => entry.language.toLowerCase() == language.toLowerCase())
      .toList(growable: false);
}

class SignAnalysisResult {
  const SignAnalysisResult({
    this.type = 'utterance_result',
    this.utteranceId = '',
    required this.status,
    required this.gestureLabel,
    required this.caption,
    this.ttsText,
    required this.confidence,
    required this.glossTrace,
    this.hypotheses = const <Map<String, dynamic>>[],
    this.modelVersion = '',
    this.latencyMs = const <String, dynamic>{},
    this.detail = '',
    this.repairAction,
    this.reasonCodes = const <String>[],
  });

  final String type;
  final String utteranceId;
  final String status;
  final String gestureLabel;
  final String caption;
  final String? ttsText;
  final double confidence;
  final List<String> glossTrace;
  final List<Map<String, dynamic>> hypotheses;
  final String modelVersion;
  final Map<String, dynamic> latencyMs;
  final String detail;
  final String? repairAction;
  final List<String> reasonCodes;

  bool get needsBackend => status == 'candidate' || status == 'unknown';
  int? get totalLatencyMs => (latencyMs['total'] as num?)?.toInt();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    'utterance_id': utteranceId,
    'status': status,
    'caption': caption,
    'tts_text': ttsText,
    'confidence': confidence,
    'gloss_trace': glossTrace,
    'hypotheses': hypotheses,
    'model_version': modelVersion,
    'latency_ms': latencyMs,
  };

  factory SignAnalysisResult.fromJson(Map<String, dynamic> json) {
    final rawGlossTrace = json['gloss_trace'] ?? json['gloss_id_trace'];
    final glossTrace = (rawGlossTrace as List<dynamic>? ?? <dynamic>[])
        .whereType<String>()
        .toList(growable: false);
    final caption =
        json['caption'] as String? ??
        json['message'] as String? ??
        'No caption returned.';
    final fallbackLabel = glossTrace.isEmpty
        ? 'unknown'
        : glossTrace.join(', ').toLowerCase();
    final rawHypotheses = json['hypotheses'];
    final hypotheses = rawHypotheses is List
        ? rawHypotheses
              .whereType<Map>()
              .map((value) => Map<String, dynamic>.from(value))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
    final rawLatency = json['latency_ms'];
    final latencyMs = rawLatency is Map
        ? Map<String, dynamic>.from(rawLatency)
        : const <String, dynamic>{};

    final rawReasons = json['reason_codes'];
    final reasonCodes = rawReasons is List
        ? rawReasons.whereType<String>().toList(growable: false)
        : const <String>[];

    return SignAnalysisResult(
      type: json['type'] as String? ?? 'utterance_result',
      utteranceId: json['utterance_id'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      gestureLabel: json['gesture_label'] as String? ?? fallbackLabel,
      caption: caption,
      ttsText: json['tts_text'] as String?,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      glossTrace: glossTrace,
      hypotheses: hypotheses,
      modelVersion:
          json['model_version'] as String? ??
          json['classifier_version'] as String? ??
          '',
      latencyMs: latencyMs,
      detail:
          json['detail'] as String? ??
          json['message'] as String? ??
          '',
      repairAction: json['action'] as String?,
      reasonCodes: reasonCodes,
    );
  }
}

/// A small local feature readout, not a claim of full ASL translation.
///
/// Word-level recognition needs a trained sequence model. This service makes
/// the handshape/movement signal visible immediately and gives the backend a
/// stable payload to classify with a language-specific model.
class SignAnalysisService {
  SignAnalysisResult analyze(List<LandmarkFrame> frames) {
    if (frames.isEmpty || frames.every((frame) => frame.hands.isEmpty)) {
      return const SignAnalysisResult(
        status: 'no_signal',
        gestureLabel: 'No hand signal',
        caption: 'Show your hands to begin tracking.',
        confidence: 0,
        glossTrace: <String>[],
      );
    }

    final tracked = frames.where((frame) => frame.hands.isNotEmpty).toList();
    final openness =
        tracked.last.hands
            .map((hand) => hand.openness)
            .reduce((left, right) => left + right) /
        tracked.last.hands.length;
    final geometry = tracked.last.handCoordinateAnalysis;
    final label = _gestureLabel(openness, tracked.last);
    final confidence =
        (tracked.last.trackingConfidence * .65 + (openness > .1 ? .35 : .12))
            .clamp(0.0, 0.99);

    return SignAnalysisResult(
      status: 'candidate',
      gestureLabel: label,
      caption: 'Hand sequence captured — send it to the sign model.',
      confidence: confidence,
      glossTrace: <String>[label.toUpperCase()],
      detail:
          '${tracked.length} frames · ${tracked.last.hands.length} hand(s) · '
          '${geometry.isEmpty ? 'no 3D geometry' : '3D coordinates analyzed'}',
    );
  }

  String _gestureLabel(double openness, LandmarkFrame frame) {
    if (frame.hands.any((hand) => hand.openness >= .8)) return 'open hand';
    if (frame.hands.every((hand) => hand.openness <= .2)) return 'closed hand';
    if (frame.hands.any(
      (hand) => hand.openness >= .35 && hand.openness <= .5,
    )) {
      return 'partial handshape';
    }
    return 'unknown handshape';
  }
}
