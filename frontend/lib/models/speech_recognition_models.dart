enum SpeechServiceStatus {
  uninitialized,
  initializing,
  ready,
  starting,
  listening,
  stopping,
  unavailable,
  error,
}

class SpeechLocale {
  const SpeechLocale({required this.localeId, required this.name});

  final String localeId;
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpeechLocale && localeId == other.localeId && name == other.name;

  @override
  int get hashCode => Object.hash(localeId, name);
}

class SpeechRecognitionUpdate {
  const SpeechRecognitionUpdate({
    required this.transcript,
    required this.isFinal,
    this.confidence,
  });

  final String transcript;
  final bool isFinal;
  final double? confidence;
}

class SpeechRecognitionErrorInfo {
  const SpeechRecognitionErrorInfo({
    required this.message,
    required this.isPermanent,
  });

  final String message;
  final bool isPermanent;
}
