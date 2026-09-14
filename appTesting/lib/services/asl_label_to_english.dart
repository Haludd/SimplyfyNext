import '../models/asl_recognition_models.dart';

/// Converts the PopSign label vocabulary into the lexical English tokens
/// required by TranslatedSignUtterance v1. The recognizer's labels are useful
/// model identifiers, but labels such as `thankyou` are not wire-safe English
/// words on their own.
final class AslLabelToEnglish {
  const AslLabelToEnglish();

  static const Map<String, List<String>> _compoundLabels =
      <String, List<String>>{
        'callonphone': <String>['CALL', 'ON', 'PHONE'],
        'frenchfries': <String>['FRENCH', 'FRIES'],
        'glasswindow': <String>['GLASS', 'WINDOW'],
        'haveto': <String>['HAVE', 'TO'],
        'hesheit': <String>['HE'],
        'icecream': <String>['ICE', 'CREAM'],
        'minemy': <String>['MINE'],
        'thankyou': <String>['THANK', 'YOU'],
        'weus': <String>['WE'],
      };

  /// A model result becomes one or more words. Alternative hypotheses are
  /// only retained for a one-word translation, because v1 alternatives each
  /// contain exactly one lexical word.
  EnglishLabelTranslation translate(AslRecognitionResult result) {
    final label = result.word;
    if (!result.isRecognized || label == null) {
      throw ArgumentError.value(result, 'result', 'must contain a word');
    }
    final words = translateLabel(label);
    final alternatives = words.length == 1
        ? _alternatives(
            result.alternatives,
            primary: words.single,
            primaryConfidence: result.confidence,
          )
        : const <EnglishLabelAlternative>[];
    return EnglishLabelTranslation(words: words, alternatives: alternatives);
  }

  List<String> translateLabel(String label) {
    final normalized = label.trim().toLowerCase();
    final compound = _compoundLabels[normalized];
    if (compound != null) return List<String>.unmodifiable(compound);

    final words = normalized
        .split(RegExp(r'[\s_]+'))
        .where((word) => word.isNotEmpty)
        .map((word) => word.toUpperCase())
        .toList(growable: false);
    if (words.isEmpty || words.any((word) => !_isEnglishToken(word))) {
      throw ArgumentError.value(
        label,
        'label',
        'cannot be translated into contract-safe English words',
      );
    }
    return List<String>.unmodifiable(words);
  }

  List<EnglishLabelAlternative> _alternatives(
    List<AslRecognitionCandidate> candidates, {
    required String primary,
    required double primaryConfidence,
  }) {
    final alternatives = <EnglishLabelAlternative>[];
    final seen = <String>{primary};
    for (final candidate in candidates) {
      if (candidate.rank <= 1 || alternatives.length >= 4) continue;
      try {
        final words = translateLabel(candidate.word);
        if (words.length != 1 || !seen.add(words.single)) continue;
        final confidence = candidate.confidence;
        if (!confidence.isFinite ||
            confidence < 0 ||
            confidence > primaryConfidence) {
          continue;
        }
        alternatives.add(
          EnglishLabelAlternative(word: words.single, confidence: confidence),
        );
      } on ArgumentError {
        // An untranslatable classifier label must not enter the wire payload.
      }
    }
    alternatives.sort(
      (left, right) => right.confidence.compareTo(left.confidence),
    );
    return List<EnglishLabelAlternative>.unmodifiable(alternatives);
  }

  static final RegExp _englishToken = RegExp(r"^[A-Z0-9]+(?:['-][A-Z0-9]+)*$");

  static bool _isEnglishToken(String word) => _englishToken.hasMatch(word);
}

final class EnglishLabelTranslation {
  EnglishLabelTranslation({
    required List<String> words,
    List<EnglishLabelAlternative> alternatives =
        const <EnglishLabelAlternative>[],
  }) : words = List<String>.unmodifiable(words),
       alternatives = List<EnglishLabelAlternative>.unmodifiable(alternatives);

  final List<String> words;
  final List<EnglishLabelAlternative> alternatives;
}

final class EnglishLabelAlternative {
  const EnglishLabelAlternative({required this.word, required this.confidence});

  final String word;
  final double confidence;
}
