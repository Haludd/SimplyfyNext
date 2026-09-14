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
      _englishWordPattern.hasMatch(value);

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
  userCommit('user_commit'),
  pauseTimeout('pause_timeout'),
  modelBoundary('model_boundary');

  const TranslatedSignUtteranceCompletionReason(this.wireValue);

  final String wireValue;
}

enum TranslatedSignUtteranceConfidenceKind {
  calibratedProbability('calibrated_probability'),
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
    this.calibrationVersion,
  }) {
    _validateIdentifier(recognizerId, 'producer.recognizer_id');
    _validateIdentifier(recognizerVersion, 'producer.recognizer_version');
    _validateIdentifier(translatorId, 'producer.translator_id');
    _validateIdentifier(translatorVersion, 'producer.translator_version');
    _validateIdentifier(vocabularyVersion, 'producer.vocabulary_version');
    if (confidenceKind ==
        TranslatedSignUtteranceConfidenceKind.calibratedProbability) {
      final version = calibrationVersion;
      if (version == null) {
        _invalid(
          'producer.calibration_version is required for '
          'calibrated_probability',
        );
      }
      _validateIdentifier(version, 'producer.calibration_version');
    } else if (calibrationVersion != null) {
      _validateIdentifier(calibrationVersion!, 'producer.calibration_version');
    }
  }

  final String recognizerId;
  final String recognizerVersion;
  final String translatorId;
  final String translatorVersion;
  final String vocabularyVersion;
  final TranslatedSignUtteranceConfidenceKind confidenceKind;
  final String? calibrationVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'recognizer_id': recognizerId,
    'recognizer_version': recognizerVersion,
    'translator_id': translatorId,
    'translator_version': translatorVersion,
    'vocabulary_version': vocabularyVersion,
    'confidence_kind': confidenceKind.wireValue,
    if (calibrationVersion != null) 'calibration_version': calibrationVersion,
  };

  @override
  bool operator ==(Object other) =>
      other is TranslatedSignUtteranceProducer &&
      recognizerId == other.recognizerId &&
      recognizerVersion == other.recognizerVersion &&
      translatorId == other.translatorId &&
      translatorVersion == other.translatorVersion &&
      vocabularyVersion == other.vocabularyVersion &&
      confidenceKind == other.confidenceKind &&
      calibrationVersion == other.calibrationVersion;

  @override
  int get hashCode => Object.hash(
    recognizerId,
    recognizerVersion,
    translatorId,
    translatorVersion,
    vocabularyVersion,
    confidenceKind,
    calibrationVersion,
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
    this.repairId,
  }) : words = List<TranslatedSignWordToken>.unmodifiable(words) {
    if (!TranslatedSignUtteranceContract.isValidUuid(messageId)) {
      _invalid('message_id must be a UUID string');
    }
    _validateSafeInteger(clientSequence, 'client_sequence');
    if (repairId != null &&
        !TranslatedSignUtteranceContract.isValidUuid(repairId!)) {
      _invalid('repair_id must be a UUID string');
    }
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

  final String messageId;
  final int clientSequence;
  final TranslatedSignUtteranceCompletionReason completionReason;
  final String? repairId;
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
    if (repairId != null) 'repair_id': repairId,
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
