import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/speech_recognition_models.dart';
import 'theme.dart';

/// On-device speech captions for the signer: what the hearing person just said,
/// in large type. It was a permanent card on the translating screen; it is a
/// mode you opt into, so it now opens from the menu.
Future<void> showSpeechCaptionsSheet(
  BuildContext context,
  AppController controller,
) async {
  await showSbSheet<void>(
    context,
    builder: (sheetContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _SpeechCaptions(controller: controller),
    ),
  );
}

class _SpeechCaptions extends StatelessWidget {
  const _SpeechCaptions({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final speech = controller.speechToText;
    final status = speech.status;
    final confirmed = speech.finalTranscript.trim();
    final partial = speech.partialTranscript.trim();
    final hasTranscript = confirmed.isNotEmpty || partial.isNotEmpty;
    final isActive = _isActive(status);
    final isStopping = status == SpeechServiceStatus.stopping;
    final locale = speech.locale;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SheetTitle(
            'Speech captions',
            trailing: locale == null
                ? null
                : _LocaleMenu(
                    selected: locale,
                    locales: speech.availableLocales,
                    enabled: !isActive && !isStopping,
                    onSelected: speech.selectLocale,
                  ),
          ),
          Container(
            key: const ValueKey<String>('speech-caption-card'),
            margin: const EdgeInsets.symmetric(horizontal: Sb.gutter),
            padding: const EdgeInsets.all(18),
            constraints: const BoxConstraints(minHeight: 130),
            decoration: BoxDecoration(
              color: Sb.surface,
              borderRadius: BorderRadius.circular(Sb.radiusLarge),
            ),
            alignment: Alignment.topLeft,
            child: Semantics(
              key: const ValueKey<String>('spoken-caption-text'),
              container: true,
              liveRegion: confirmed.isNotEmpty,
              label: confirmed.isNotEmpty
                  ? 'Final spoken caption: $confirmed'
                  : partial.isNotEmpty
                  ? 'Draft spoken caption: $partial'
                  : 'No spoken caption yet',
              child: ExcludeSemantics(
                child: hasTranscript
                    ? SelectableText.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            if (confirmed.isNotEmpty)
                              TextSpan(
                                text: confirmed,
                                style: const TextStyle(color: Sb.text),
                              ),
                            if (confirmed.isNotEmpty && partial.isNotEmpty)
                              const TextSpan(text: ' '),
                            if (partial.isNotEmpty)
                              TextSpan(
                                text: partial,
                                style: const TextStyle(color: Sb.textMuted),
                              ),
                          ],
                          style: const TextStyle(
                            fontSize: 24,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : const Text(
                        'Start listening, then let the other person speak.',
                        style: TextStyle(
                          color: Sb.textMuted,
                          fontSize: 19,
                          height: 1.4,
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sb.gutter),
            child: Semantics(
              container: true,
              liveRegion:
                  status == SpeechServiceStatus.listening ||
                  status == SpeechServiceStatus.error ||
                  status == SpeechServiceStatus.unavailable,
              label: _statusLabel(status, speech.lastError?.message),
              child: ExcludeSemantics(
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _statusColor(status),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusLabel(status, speech.lastError?.message),
                        style: const TextStyle(
                          color: Sb.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sb.gutter),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey<String>('toggle-speech-captioning'),
                    onPressed: isStopping
                        ? null
                        : controller.toggleSpeechCaptioning,
                    icon: Icon(
                      isActive ? Icons.stop_rounded : Icons.mic,
                      size: 20,
                    ),
                    label: Text(
                      isActive
                          ? 'Stop listening'
                          : status == SpeechServiceStatus.error ||
                                status == SpeechServiceStatus.unavailable
                          ? 'Try again'
                          : 'Start listening',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: isActive ? Sb.bad : Sb.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  key: const ValueKey<String>('clear-speech-caption'),
                  tooltip: 'Clear caption',
                  onPressed: hasTranscript && !isActive && !isStopping
                      ? controller.clearSpeechCaption
                      : null,
                  icon: const Icon(Icons.backspace_outlined),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(Sb.gutter, 16, Sb.gutter, 24),
            child: Text(
              'Recognition uses this device’s speech service and may need a connection. No audio leaves the app.',
              style: TextStyle(color: Sb.textFaint, fontSize: 11, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  static bool _isActive(SpeechServiceStatus status) =>
      status == SpeechServiceStatus.initializing ||
      status == SpeechServiceStatus.starting ||
      status == SpeechServiceStatus.listening;

  static Color _statusColor(SpeechServiceStatus status) => switch (status) {
    SpeechServiceStatus.ready => Sb.good,
    SpeechServiceStatus.starting ||
    SpeechServiceStatus.listening => Sb.primaryStrong,
    SpeechServiceStatus.unavailable || SpeechServiceStatus.error => Sb.bad,
    SpeechServiceStatus.uninitialized ||
    SpeechServiceStatus.initializing ||
    SpeechServiceStatus.stopping => Sb.warn,
  };

  static String _statusLabel(SpeechServiceStatus status, String? error) =>
      switch (status) {
        SpeechServiceStatus.uninitialized =>
          'Microphone permission is requested when you start',
        SpeechServiceStatus.initializing =>
          'Requesting microphone and speech access…',
        SpeechServiceStatus.ready => 'Ready for a short spoken message',
        SpeechServiceStatus.starting => 'Starting the microphone…',
        SpeechServiceStatus.listening => 'Listening… speak naturally',
        SpeechServiceStatus.stopping => 'Finishing the caption…',
        SpeechServiceStatus.unavailable =>
          'Speech recognition is unavailable on this device',
        SpeechServiceStatus.error => friendlySpeechError(error),
      };
}

/// Shared with the chat composer so both surfaces explain a failure the same
/// way.
String friendlySpeechError(String? error) {
  final normalized = (error ?? '').toLowerCase();
  if (normalized.contains('permission') || normalized.contains('denied')) {
    return 'Microphone permission was denied';
  }
  if (normalized.contains('network')) {
    return 'Speech recognition needs a network connection';
  }
  if (normalized.contains('no_match') || normalized.contains('no match')) {
    return 'Nothing was recognised · try again and speak clearly';
  }
  if (normalized.contains('busy')) {
    return 'The speech recogniser is busy · try again';
  }
  return error == null || error.trim().isEmpty
      ? 'Speech recognition stopped unexpectedly'
      : 'Speech recognition error · $error';
}

class _LocaleMenu extends StatelessWidget {
  const _LocaleMenu({
    required this.selected,
    required this.locales,
    required this.enabled,
    required this.onSelected,
  });

  final SpeechLocale selected;
  final List<SpeechLocale> locales;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final canChoose = enabled && locales.length > 1;
    return PopupMenuButton<String>(
      enabled: canChoose,
      tooltip: 'Spoken language',
      initialValue: selected.localeId,
      onSelected: onSelected,
      itemBuilder: (context) => locales
          .map(
            (locale) => PopupMenuItem<String>(
              value: locale.localeId,
              child: Text(locale.name),
            ),
          )
          .toList(growable: false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Sb.surface,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              selected.name,
              style: const TextStyle(color: Sb.textMuted, fontSize: 12),
            ),
            if (canChoose)
              const Icon(Icons.expand_more, color: Sb.textMuted, size: 16),
          ],
        ),
      ),
    );
  }
}
