import 'package:flutter_tts/flutter_tts.dart';

/// Speaks the latest translated caption on the user's device.
///
/// This is deliberately separate from sign capture: the next processing stage
/// can pass its returned `tts_text` to [speak].
class TextToSpeechService {
  TextToSpeechService({FlutterTts? engine}) : _engine = engine ?? FlutterTts();

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
  bool _voiceConfigured = false;
  Map<String, String>? _selectedVoice;

  Future<void> speak(String text) async {
    _ensureNotDisposed();
    final value = text.trim();
    if (value.isEmpty) return;

    await _engine.stop();
    if (!_voiceConfigured) {
      await _engine.setLanguage(preferredVoiceLocale);
      await _configurePreferredVoice();
    } else if (_selectedVoice != null) {
      // Some platforms reset the voice when a new utterance starts.
      try {
        await _engine.setVoice(_selectedVoice!);
      } catch (_) {
        // Keep speaking with the platform's already-selected fallback voice.
      }
    }
    await _engine.setSpeechRate(.48);
    await _engine.setPitch(1.0);
    await _engine.setVolume(1.0);
    await _engine.speak(value);
  }

  /// Selects the same named voice for every utterance in this app session.
  ///
  /// Voice names are supplied by the platform, so this cannot install
  /// Samantha on a device that does not have it. In that case setLanguage()
  /// above has already selected the device's en-US voice as a fallback.
  Future<void> _configurePreferredVoice() async {
    if (_voiceConfigured) return;

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
    } finally {
      _voiceConfigured = true;
    }
  }

  Future<void> stop() async {
    if (_isDisposed) return;
    await _engine.stop();
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
