import 'package:flutter_tts/flutter_tts.dart';

/// Speaks the latest translated caption on the user's device.
///
/// This is deliberately separate from sign capture: the next processing stage
/// can pass its returned `tts_text` to [speak].
class TextToSpeechService {
  TextToSpeechService({FlutterTts? engine}) : _engine = engine ?? FlutterTts() {
    _configureHandlers();
  }

  /// The voice profile used by this app.
  ///
  /// `flutter_tts` uses voices installed by the browser/operating system, so
  /// the exact voice must exist on the device. Samantha is available on the
  /// Apple platforms used for development and is also exposed by many
  /// browsers. If it is unavailable, the service keeps the en-US system voice
  /// selected rather than failing speech completely.
  static const String preferredVoiceName = 'Samantha';
  static const String preferredVoiceLocale = 'en-US';

  final FlutterTts _engine;
  bool _isDisposed = false;
  bool _engineConfigured = false;
  Map<String, String>? _selectedVoice;
  bool _isSpeaking = false;

  /// Most Web Speech API voices cut the audio output stream the instant the
  /// last phoneme ends, which browsers render as an audible click. Speaking
  /// a hair of trailing silence gives the engine somewhere to fade into
  /// instead of stopping cold, and it is inaudible on every platform tested.
  static const String _trailingSilence = '​';

  Future<void> speak(String text) async {
    _ensureNotDisposed();
    final value = text.trim();
    if (value.isEmpty) return;

    // Cancelling speech that is not in progress produces the same abrupt
    // click as cancelling mid-utterance on some browsers, so this only stops
    // the engine when it is actually speaking.
    if (_isSpeaking) await _engine.stop();
    await _configureEngine();
    await _engine.speak('$value$_trailingSilence');
  }

  /// One-time setup: everything here used to run before every single
  /// utterance, which reset the underlying engine that much more often and
  /// made the end-of-speech click more frequent.
  Future<void> _configureEngine() async {
    if (_engineConfigured) return;
    _engineConfigured = true;
    // Lets `stop()`/dispose() know speech has actually finished instead of
    // only firing-and-forgetting; also avoids overlapping utterances, a
    // second common source of an audible click when one cuts off another.
    try {
      await _engine.awaitSpeakCompletion(true);
    } catch (_) {
      // Not supported on every platform; speech still works without it.
    }
    await _engine.setLanguage(preferredVoiceLocale);
    await _configurePreferredVoice();
    await _engine.setSpeechRate(.48);
    await _engine.setPitch(1.0);
    await _engine.setVolume(1.0);
  }

  void _configureHandlers() {
    _engine.setStartHandler(() => _isSpeaking = true);
    _engine.setCompletionHandler(() => _isSpeaking = false);
    _engine.setCancelHandler(() => _isSpeaking = false);
    _engine.setErrorHandler((_) => _isSpeaking = false);
  }

  /// Selects the same named voice for every utterance in this app session.
  ///
  /// Voice names are supplied by the platform, so this cannot install
  /// Samantha on a device that does not have it. In that case setLanguage()
  /// above has already selected the device's en-US voice as a fallback.
  Future<void> _configurePreferredVoice() async {
    try {
      final rawVoices = await _engine.getVoices;
      if (rawVoices is List) {
        final matchingVoice = rawVoices.cast<dynamic>().where((voice) {
          if (voice is! Map) return false;
          final name = voice['name']?.toString().toLowerCase();
          final locale = voice['locale']?.toString().toLowerCase();
          return name == preferredVoiceName.toLowerCase() &&
              locale == preferredVoiceLocale.toLowerCase();
        }).firstOrNull;

        if (matchingVoice is Map) {
          _selectedVoice = <String, String>{
            'name': matchingVoice['name'].toString(),
            'locale': matchingVoice['locale'].toString(),
          };
          await _engine.setVoice(_selectedVoice!);
        }
      }
    } catch (_) {
      // Keep the en-US language fallback if voice selection is unsupported.
    }
  }

  Future<void> stop() async {
    if (_isDisposed) return;
    await _engine.stop();
    _isSpeaking = false;
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await _engine.stop();
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('TextToSpeechService has been disposed.');
    }
  }
}
