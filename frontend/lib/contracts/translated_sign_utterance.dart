import 'dart:convert';

/// The frozen frontend-to-room ingress contract for one completed ASL
/// utterance. Camera frames, landmarks, feature vectors and classifier
/// tensors deliberately have no representation in this model.
abstract final class TranslatedSignUtteranceContract {
  static const String type = 'translated_sign_utterance';
  static const String schemaVersion = '1.0';
  static const String sourceLanguage = 'asl';
  static const String targetLanguage = 'en';

  static const int maxMessageBytes = 16 * 1024;
  static const int maxWords = 64;
  static const int maxAlternatives = 4;
  static const int maxSafeJsonInteger = 9007199254740991;

  static final RegExp _identifierPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$',
  );
  static final RegExp _englishWordPattern = RegExp(
    r"^[A-Z0-9]+(?:['-][A-Z0-9]+)*$",
  );
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
  );

  static bool isValidIdentifier(String value) =>
      _identifierPattern.hasMatch(value);

  static bool isValidEnglishWord(String value) =>
      value.length <= 80 && _englishWordPattern.hasMatch(value);

  /// Retained retries should reuse the original UUID text unchanged.
  static bool isValidUuid(String value) => _uuidPattern.hasMatch(value);
}

final class TranslatedSignUtteranceValidationException implements Exception {
  const TranslatedSignUtteranceValidationException(this.message);

  final String message;

  @override
  String toString() => 'TranslatedSignUtteranceValidationException: $message';
}

enum TranslatedSignUtteranceCompletionReason {
  userCommit('user_commit');

  const TranslatedSignUtteranceCompletionReason(this.wireValue);

  final String wireValue;
}

enum TranslatedSignUtteranceConfidenceKind {
  normalizedModelScore('normalized_model_score');

  const TranslatedSignUtteranceConfidenceKind(this.wireValue);

  final String wireValue;
}

/// Identifies the local recognizer and translator profile used to make every
/// word in one utterance. The backend is responsible for allow-listing it.
final class TranslatedSignUtteranceProducer {
  TranslatedSignUtteranceProducer({
    required this.recognizerId,
    required this.recognizerVersion,
    required this.translatorId,
    required this.translatorVersion,
    required this.vocabularyVersion,
    required this.confidenceKind,
  }) {
    _validateIdentifier(recognizerId, 'producer.recognizer_id');
    _validateIdentifier(recognizerVersion, 'producer.recognizer_version');
    _validateIdentifier(translatorId, 'producer.translator_id');
    _validateIdentifier(translatorVersion, 'producer.translator_version');
    _validateIdentifier(vocabularyVersion, 'producer.vocabulary_version');
    if (recognizerId != 'signchat_asl_signs_onnx' ||
        recognizerVersion != 'signchat_asl_signs_onnx' ||
        translatorId != 'asl_label_to_english' ||
        translatorVersion != '1.0.0' ||
        vocabularyVersion != 'popsign_250_en_v1' ||
        confidenceKind !=
            TranslatedSignUtteranceConfidenceKind.normalizedModelScore) {
      _invalid('producer must match the frozen PopSign 250 profile');
    }
  }

  factory TranslatedSignUtteranceProducer.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const <String>{
      'recognizer_id',
      'recognizer_version',
      'translator_id',
      'translator_version',
      'vocabulary_version',
      'confidence_kind',
    });
    if (json['confidence_kind'] != 'normalized_model_score') {
      _invalid('producer.confidence_kind must be normalized_model_score');
    }
    return TranslatedSignUtteranceProducer(
      recognizerId: _requiredString(json, 'recognizer_id'),
      recognizerVersion: _requiredString(json, 'recognizer_version'),
      translatorId: _requiredString(json, 'translator_id'),
      translatorVersion: _requiredString(json, 'translator_version'),
      vocabularyVersion: _requiredString(json, 'vocabulary_version'),
      confidenceKind:
          TranslatedSignUtteranceConfidenceKind.normalizedModelScore,
    );
  }

  final String recognizerId;
  final String recognizerVersion;
  final String translatorId;
  final String translatorVersion;
  final String vocabularyVersion;
  final TranslatedSignUtteranceConfidenceKind confidenceKind;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'recognizer_id': recognizerId,
    'recognizer_version': recognizerVersion,
    'translator_id': translatorId,
    'translator_version': translatorVersion,
    'vocabulary_version': vocabularyVersion,
    'confidence_kind': confidenceKind.wireValue,
  };

  @override
  bool operator ==(Object other) =>
      other is TranslatedSignUtteranceProducer &&
      recognizerId == other.recognizerId &&
      recognizerVersion == other.recognizerVersion &&
      translatorId == other.translatorId &&
      translatorVersion == other.translatorVersion &&
      vocabularyVersion == other.vocabularyVersion &&
      confidenceKind == other.confidenceKind;

  @override
  int get hashCode => Object.hash(
    recognizerId,
    recognizerVersion,
    translatorId,
    translatorVersion,
    vocabularyVersion,
    confidenceKind,
  );
}

final class TranslatedSignWordAlternative {
  TranslatedSignWordAlternative({
    required this.rank,
    required this.word,
    required this.confidence,
  }) {
    if (rank < 2 || rank > 5) {
      _invalid('alternative.rank must be between 2 and 5');
    }
    _validateEnglishWord(word, 'alternative.word');
    _validateScore(confidence, 'alternative.confidence');
  }

  factory TranslatedSignWordAlternative.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const <String>{'rank', 'word', 'confidence'});
    return TranslatedSignWordAlternative(
      rank: _requiredInteger(json, 'rank'),
      word: _requiredString(json, 'word'),
      confidence: _requiredScore(json, 'confidence'),
    );
  }

  final int rank;
  final String word;
  final double confidence;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rank': rank,
    'word': word,
    'confidence': confidence,
  };
}

final class TranslatedSignWordToken {
  TranslatedSignWordToken({
    required this.index,
    required this.tokenId,
    required this.word,
    required this.confidence,
    List<TranslatedSignWordAlternative> alternatives =
        const <TranslatedSignWordAlternative>[],
  }) : alternatives = List<TranslatedSignWordAlternative>.unmodifiable(
         alternatives,
       ) {
    if (index < 0 || index >= TranslatedSignUtteranceContract.maxWords) {
      _invalid('word.index must be between 0 and 63');
    }
    _validateIdentifier(tokenId, 'word.token_id');
    _validateEnglishWord(word, 'word.word');
    _validateScore(confidence, 'word.confidence');
    if (this.alternatives.length >
        TranslatedSignUtteranceContract.maxAlternatives) {
      _invalid('word.alternatives cannot contain more than 4 entries');
    }

    final words = <String>{word};
    var previousScore = confidence;
    for (var index = 0; index < this.alternatives.length; index += 1) {
      final alternative = this.alternatives[index];
      final expectedRank = index + 2;
      if (alternative.rank != expectedRank) {
        _invalid(
          'word.alternatives ranks must be contiguous from 2; expected '
          '$expectedRank at index $index',
        );
      }
      if (!words.add(alternative.word)) {
        _invalid('word and alternatives must not repeat "${alternative.word}"');
      }
      if (alternative.confidence > previousScore) {
        _invalid('word scores must be in non-increasing order');
      }
      previousScore = alternative.confidence;
    }
  }

  factory TranslatedSignWordToken.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const <String>{
      'index',
      'token_id',
      'word',
      'confidence',
      'alternatives',
    });
    final rawAlternatives = json['alternatives'];
    if (rawAlternatives is! List) {
      _invalid('word.alternatives must be an array');
    }
    return TranslatedSignWordToken(
      index: _requiredInteger(json, 'index'),
      tokenId: _requiredString(json, 'token_id'),
      word: _requiredString(json, 'word'),
      confidence: _requiredScore(json, 'confidence'),
      alternatives: rawAlternatives
          .map((value) {
            if (value is! Map) {
              _invalid('word.alternatives must contain objects');
            }
            return TranslatedSignWordAlternative.fromJson(
              Map<String, dynamic>.from(value),
            );
          })
          .toList(growable: false),
    );
  }

  final int index;
  final String tokenId;
  final String word;
  final double confidence;
  final List<TranslatedSignWordAlternative> alternatives;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'index': index,
    'token_id': tokenId,
    'word': word,
    'confidence': confidence,
    'alternatives': alternatives
        .map((alternative) => alternative.toJson())
        .toList(growable: false),
  };
}

/// One immutable, final sign utterance. Retain this exact object and resend
/// it if the acknowledgement is lost; never rebuild it with a new ID or
/// sequence number for a retry.
final class TranslatedSignUtterance {
  TranslatedSignUtterance({
    required this.messageId,
    required this.clientSequence,
    required this.completionReason,
    required this.producer,
    required List<TranslatedSignWordToken> words,
  }) : words = List<TranslatedSignWordToken>.unmodifiable(words) {
    if (!TranslatedSignUtteranceContract.isValidUuid(messageId)) {
      _invalid('message_id must be a UUID string');
    }
    _validateSafeInteger(clientSequence, 'client_sequence');
    if (this.words.isEmpty ||
        this.words.length > TranslatedSignUtteranceContract.maxWords) {
      _invalid('words must contain between 1 and 64 entries');
    }

    final tokenIds = <String>{};
    for (var index = 0; index < this.words.length; index += 1) {
      final word = this.words[index];
      if (word.index != index) {
        _invalid(
          'words indices must be contiguous from 0; expected $index, got '
          '${word.index}',
        );
      }
      if (!tokenIds.add(word.tokenId)) {
        _invalid('words.token_id values must be unique');
      }
    }

    if (utf8.encode(toWireJson()).length >
        TranslatedSignUtteranceContract.maxMessageBytes) {
      _invalid('serialized utterance exceeds the 16 KiB transport limit');
    }
  }

  factory TranslatedSignUtterance.fromJson(Map<String, dynamic> json) {
    _exactKeys(json, const <String>{
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
    if (json['type'] != TranslatedSignUtteranceContract.type ||
        json['schema_version'] !=
            TranslatedSignUtteranceContract.schemaVersion ||
        json['source_language'] !=
            TranslatedSignUtteranceContract.sourceLanguage ||
        json['target_language'] !=
            TranslatedSignUtteranceContract.targetLanguage ||
        json['is_final'] is! bool ||
        json['is_final'] != true ||
        json['completion_reason'] != 'user_commit') {
      _invalid('utterance contains an unsupported v1 discriminator');
    }
    final rawProducer = json['producer'];
    final rawWords = json['words'];
    if (rawProducer is! Map) _invalid('producer must be an object');
    if (rawWords is! List) _invalid('words must be an array');
    return TranslatedSignUtterance(
      messageId: _requiredString(json, 'message_id'),
      clientSequence: _requiredInteger(json, 'client_sequence'),
      completionReason: TranslatedSignUtteranceCompletionReason.userCommit,
      producer: TranslatedSignUtteranceProducer.fromJson(
        Map<String, dynamic>.from(rawProducer),
      ),
      words: rawWords
          .map((value) {
            if (value is! Map) _invalid('words must contain objects');
            return TranslatedSignWordToken.fromJson(
              Map<String, dynamic>.from(value),
            );
          })
          .toList(growable: false),
    );
  }

  factory TranslatedSignUtterance.fromWireJson(String raw) {
    if (utf8.encode(raw).length >
        TranslatedSignUtteranceContract.maxMessageBytes) {
      _invalid('serialized utterance exceeds the 16 KiB transport limit');
    }
    if (raw.startsWith('\ufeff') || _hasDuplicateJsonObjectKey(raw)) {
      _invalid('serialized utterance is not strict JSON');
    }
    final dynamic value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      _invalid('serialized utterance is not valid JSON');
    }
    if (value is! Map) _invalid('serialized utterance must be an object');
    return TranslatedSignUtterance.fromJson(Map<String, dynamic>.from(value));
  }

  final String messageId;
  final int clientSequence;
  final TranslatedSignUtteranceCompletionReason completionReason;
  final TranslatedSignUtteranceProducer producer;
  final List<TranslatedSignWordToken> words;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': TranslatedSignUtteranceContract.type,
    'schema_version': TranslatedSignUtteranceContract.schemaVersion,
    'message_id': messageId,
    'client_sequence': clientSequence,
    'source_language': TranslatedSignUtteranceContract.sourceLanguage,
    'target_language': TranslatedSignUtteranceContract.targetLanguage,
    'is_final': true,
    'completion_reason': completionReason.wireValue,
    'producer': producer.toJson(),
    'words': words.map((word) => word.toJson()).toList(growable: false),
  };

  String toWireJson() => jsonEncode(toJson());
}

void _validateIdentifier(String value, String path) {
  if (!TranslatedSignUtteranceContract.isValidIdentifier(value)) {
    _invalid('$path must be an identifier of 1 to 80 characters');
  }
}

void _validateEnglishWord(String value, String path) {
  if (!TranslatedSignUtteranceContract.isValidEnglishWord(value)) {
    _invalid('$path must be an uppercase English lexical token');
  }
}

void _validateScore(double value, String path) {
  if (!value.isFinite || value < 0 || value > 1) {
    _invalid('$path must be a finite number between 0 and 1');
  }
}

void _validateSafeInteger(int value, String path) {
  if (value < 0 || value > TranslatedSignUtteranceContract.maxSafeJsonInteger) {
    _invalid(
      '$path must be an integer between 0 and '
      '${TranslatedSignUtteranceContract.maxSafeJsonInteger}',
    );
  }
}

Never _invalid(String message) =>
    throw TranslatedSignUtteranceValidationException(message);

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    _invalid('object contains missing or unknown fields');
  }
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) _invalid('$key must be a string');
  return value;
}

int _requiredInteger(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  _invalid('$key must be an integer');
}

double _requiredScore(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) _invalid('$key must be a number');
  return value.toDouble();
}

bool _hasDuplicateJsonObjectKey(String source) {
  final stack = <Set<String>?>[];
  var index = 0;
  while (index < source.length) {
    final character = source.codeUnitAt(index);
    if (character == 0x7b) {
      stack.add(<String>{});
      index += 1;
      continue;
    }
    if (character == 0x5b) {
      stack.add(null);
      index += 1;
      continue;
    }
    if (character == 0x7d || character == 0x5d) {
      if (stack.isNotEmpty) stack.removeLast();
      index += 1;
      continue;
    }
    if (character != 0x22) {
      index += 1;
      continue;
    }
    final start = ++index;
    var escaped = false;
    while (index < source.length) {
      final current = source.codeUnitAt(index);
      if (!escaped && current == 0x22) break;
      if (!escaped && current == 0x5c) {
        escaped = true;
      } else {
        escaped = false;
      }
      index += 1;
    }
    if (index >= source.length) return false;
    final encodedKey = source.substring(start, index);
    index += 1;
    var lookahead = index;
    while (lookahead < source.length &&
        const <int>{
          0x20,
          0x09,
          0x0a,
          0x0d,
        }.contains(source.codeUnitAt(lookahead))) {
      lookahead += 1;
    }
    if (lookahead < source.length &&
        source.codeUnitAt(lookahead) == 0x3a &&
        stack.isNotEmpty &&
        stack.last != null &&
        !stack.last!.add(encodedKey)) {
      return true;
    }
  }
  return false;
}
