import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../models/speech_recognition_models.dart';

typedef SpeechResultCallback = void Function(SpeechRecognitionUpdate result);
typedef SpeechStatusCallback = void Function(String status);
typedef SpeechErrorCallback = void Function(SpeechRecognitionErrorInfo error);

abstract interface class SpeechRecognizerAdapter {
  bool get isListening;

  Future<bool> initialize({
    required SpeechStatusCallback onStatus,
    required SpeechErrorCallback onError,
  });

  Future<List<SpeechLocale>> locales();

  Future<SpeechLocale?> systemLocale();

  Future<void> listen({
    required SpeechResultCallback onResult,
    String? localeId,
    Duration? listenFor,
    Duration? pauseFor,
  });

  Future<void> stop();

  Future<void> cancel();

  Future<void> dispose();
}

class SpeechToTextRecognizerAdapter implements SpeechRecognizerAdapter {
  SpeechToTextRecognizerAdapter({stt.SpeechToText? speechToText})
    : _speechToText = speechToText ?? stt.SpeechToText();

  final stt.SpeechToText _speechToText;

  @override
  bool get isListening => _speechToText.isListening;

  @override
  Future<bool> initialize({
    required SpeechStatusCallback onStatus,
    required SpeechErrorCallback onError,
  }) => _speechToText.initialize(
    onStatus: onStatus,
    onError: (error) => onError(
      SpeechRecognitionErrorInfo(
        message: error.errorMsg,
        isPermanent: error.permanent,
      ),
    ),
  );

  @override
  Future<List<SpeechLocale>> locales() async => (await _speechToText.locales())
      .map(
        (locale) => SpeechLocale(localeId: locale.localeId, name: locale.name),
      )
      .toList(growable: false);

  @override
  Future<SpeechLocale?> systemLocale() async {
    final locale = await _speechToText.systemLocale();
    if (locale == null) return null;
    return SpeechLocale(localeId: locale.localeId, name: locale.name);
  }

  @override
  Future<void> listen({
    required SpeechResultCallback onResult,
    String? localeId,
    Duration? listenFor,
    Duration? pauseFor,
  }) async {
    await _speechToText.listen(
      onResult: (result) => onResult(
        SpeechRecognitionUpdate(
          transcript: result.recognizedWords,
          isFinal: result.finalResult,
          confidence: result.hasConfidenceRating ? result.confidence : null,
        ),
      ),
      listenOptions: stt.SpeechListenOptions(
        cancelOnError: true,
        partialResults: true,
        autoPunctuation: true,
        listenMode: stt.ListenMode.dictation,
        localeId: localeId,
        listenFor: listenFor,
        pauseFor: pauseFor,
      ),
    );
  }

  @override
  Future<void> stop() => _speechToText.stop();

  @override
  Future<void> cancel() => _speechToText.cancel();

  @override
  Future<void> dispose() => _speechToText.cancel();
}
