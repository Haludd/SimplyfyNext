import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/room_models.dart';
import '../services/room_session_controller.dart';
import '../services/sign_analysis_service.dart';
import 'camera_stage.dart';
import 'shell_menu.dart';
import 'theme.dart';

/// The signer's main screen: the camera feed, and one line of text.
///
/// Everything else — camera controls, playback, shortcuts — is in the overflow
/// menu, so the only things competing for attention are the person signing and
/// what the app understood.
class SignScreen extends StatelessWidget {
  const SignScreen({
    super.key,
    required this.controller,
    this.room,
    this.onSelectTab,
  });

  final AppController controller;
  final RoomSessionController? room;
  final ValueChanged<ShellTab>? onSelectTab;

  @override
  Widget build(BuildContext context) {
    final cameraReady = controller.devices.cameraReady;
    return ColoredBox(
      color: Sb.cameraVoid,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CameraStage(controller: controller),
          if (!cameraReady) _CameraOffPrompt(controller: controller),
          SafeArea(
            child: Stack(
              children: <Widget>[
                Positioned(
                  top: 8,
                  right: Sb.gutter - 8,
                  child: ShellMenu(
                    appController: controller,
                    room: room,
                    onSelectTab: onSelectTab ?? (_) {},
                    cameraActions: true,
                    signActions: true,
                    onCamera: true,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _TranslationPanel(
                    controller: controller,
                    room: room,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraOffPrompt extends StatelessWidget {
  const _CameraOffPrompt({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
      decoration: BoxDecoration(
        color: Sb.overlay,
        borderRadius: BorderRadius.circular(Sb.radiusLarge),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.videocam_off_outlined, size: 30, color: Sb.textMuted),
          const SizedBox(height: 12),
          const Text(
            'Camera is off',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'SignBridge needs the camera to read your signs.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Sb.textMuted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () => controller.requestCamera(),
            child: const Text('Turn on camera'),
          ),
        ],
      ),
    ),
  );
}

class _TranslationPanel extends StatelessWidget {
  const _TranslationPanel({required this.controller, required this.room});

  final AppController controller;
  final RoomSessionController? room;

  @override
  Widget build(BuildContext context) {
    final words = controller.translatedWords;
    final sending = controller.isUtteranceSubmissionInFlight;
    final sentence = _latestOwnSentence(room);
    final caption = _caption(words, sentence, sending);
    final signList = words.isNotEmpty
        ? words
        : (controller.visibleAnalysis?.glossTrace ?? const <String>[]);
    final confidence =
        controller.visibleAnalysis?.confidence ?? controller.confidence;
    final showConfidence =
        controller.devices.cameraReady && controller.visibleAnalysis != null;
    final note = _actionableStatus(controller);
    final canSend = controller.canCommitTranslatedUtterance && !sending;

    return FractionallySizedBox(
      widthFactor: .9,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (controller.hasPendingTranslatedWords)
              _PendingWordReview(controller: controller),
            Container(
              key: const ValueKey<String>('translated-utterance-buffer'),
              padding: const EdgeInsets.fromLTRB(18, 15, 10, 15),
              decoration: BoxDecoration(
                color: Sb.overlay,
                borderRadius: BorderRadius.circular(Sb.radiusLarge),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      caption.text,
                      key: const ValueKey<String>('live-translation-text'),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 19,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: caption.muted ? Sb.textMuted : Sb.text,
                      ),
                    ),
                  ),
                  if (!caption.muted)
                    IconButton(
                      tooltip: 'Read aloud',
                      onPressed: () =>
                          controller.textToSpeech.speak(caption.text),
                      icon: const Icon(
                        Icons.volume_up_outlined,
                        size: 20,
                        color: Sb.textMuted,
                      ),
                    )
                  else
                    const SizedBox(width: 8),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (showConfidence)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Row(
                  children: <Widget>[
                    ConfidenceDot(confidence: confidence),
                    const SizedBox(width: 7),
                    Text(
                      'Confidence: ${Sb.percent(confidence)}',
                      style: _metaStyle,
                    ),
                  ],
                ),
              ),
            if (signList.isNotEmpty)
              _SignListLine(
                signs: signList,
                editable: words.isNotEmpty,
                onEdit: () => _openWordEditor(context),
              ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: Text(
                  note,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Sb.warn,
                    fontSize: 12,
                    height: 1.35,
                    shadows: <Shadow>[
                      Shadow(color: Colors.black38, blurRadius: 6),
                    ],
                  ),
                ),
              ),
            if (words.isNotEmpty || sending) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  CameraIconButton(
                    icon: Icons.backspace_outlined,
                    tooltip: 'Clear the sentence',
                    onPressed: controller.canClearTranslatedUtterance
                        ? controller.clearCaption
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey<String>(
                        'commit-translated-utterance',
                      ),
                      onPressed: canSend
                          ? controller.commitTranslatedUtterance
                          : null,
                      icon: sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.arrow_upward_rounded, size: 20),
                      label: Text(
                        sending
                            ? 'Sending…'
                            : 'Send ${words.length} word${words.length == 1 ? '' : 's'}',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openWordEditor(BuildContext context) async {
    await showSbSheet<void>(
      context,
      builder: (sheetContext) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => _WordEditor(controller: controller),
      ),
    );
  }

  /// The caption shows the sentence the room returned, or, while the signer is
  /// still building one, the individual words recognised so far.
  static _Caption _caption(
    List<String> words,
    RoomMessage? sentence,
    bool sending,
  ) {
    if (sending) return const _Caption('Sending your sentence…', true);
    if (words.isNotEmpty) return _Caption(words.join(' '), false);
    if (sentence != null) {
      if (sentence.status == 'processing') {
        return const _Caption('Translating your signs…', true);
      }
      if (sentence.status == 'repair') {
        return _Caption(
          sentence.repair?.prompt ?? 'Please sign that again.',
          true,
        );
      }
      final text = sentence.text ?? '';
      if (text.isNotEmpty) return _Caption(text, false);
    }
    return const _Caption('Sign a word to begin', true);
  }

  /// The signer's own most recent signed message, which is where the assembled
  /// sentence comes back from the backend.
  static RoomMessage? _latestOwnSentence(RoomSessionController? room) {
    final me = room?.credentials?.participantId;
    if (room == null || me == null) return null;
    RoomMessage? latest;
    for (final message in room.messages) {
      if (message.senderId == me && message.source == 'sign') latest = message;
    }
    return latest;
  }

  /// Backend chatter is diagnostic noise; only what blocks the signer is shown.
  static String? _actionableStatus(AppController controller) {
    if (!controller.isUtteranceSubmissionConfigured) {
      return 'Start a room before sending a sentence.';
    }
    final status = controller.backendStatus;
    const blockers = <String>[
      'Could not',
      'cannot',
      'not configured',
      'Add at least',
      'is busy',
      'Wait for',
    ];
    return blockers.any((blocker) => status.contains(blocker))
        ? status
        : null;
  }
}

class _Caption {
  const _Caption(this.text, this.muted);

  final String text;
  final bool muted;
}

/// Small light-on-video text for the two lines under the caption.
const TextStyle _metaStyle = TextStyle(
  color: Colors.white,
  fontSize: 13,
  fontWeight: FontWeight.w500,
  shadows: <Shadow>[Shadow(color: Colors.black45, blurRadius: 6)],
);


class _SignListLine extends StatelessWidget {
  const _SignListLine({
    required this.signs,
    required this.editable,
    required this.onEdit,
  });

  final List<String> signs;
  final bool editable;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final line = Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'Sign: ${signs.join(', ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _metaStyle,
            ),
          ),
          if (editable)
            const Icon(Icons.tune, size: 15, color: Colors.white70),
        ],
      ),
    );
    if (!editable) return line;
    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(8),
      child: line,
    );
  }
}

class _PendingWordReview extends StatelessWidget {
  const _PendingWordReview({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final words = controller.pendingTranslatedWords;
    final confidence = controller.pendingTranslatedWordConfidence;
    return Container(
      key: const ValueKey<String>('pending-translated-words-review'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(
        color: Sb.overlay,
        borderRadius: BorderRadius.circular(Sb.radius),
        border: Border.all(color: Sb.warn.withValues(alpha: .55)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  words.join(' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  confidence == null
                      ? 'Low confidence · add it?'
                      : '${Sb.percent(confidence)} confident · add it?',
                  style: const TextStyle(color: Sb.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey<String>('discard-pending-translated-words'),
            tooltip: 'Ignore',
            onPressed: controller.discardPendingTranslatedWords,
            icon: const Icon(Icons.close, color: Sb.textMuted),
          ),
          IconButton(
            key: const ValueKey<String>('add-pending-translated-words'),
            tooltip: 'Add to the sentence',
            onPressed: controller.addPendingTranslatedWords,
            icon: const Icon(Icons.check, color: Sb.primary),
          ),
        ],
      ),
    );
  }
}

/// Removes individual words and shows exactly what a send would transmit.
class _WordEditor extends StatelessWidget {
  const _WordEditor({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final words = controller.translatedWords;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SheetTitle('Sentence'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sb.gutter),
            child: words.isEmpty
                ? const Text(
                    'No words yet.',
                    style: TextStyle(color: Sb.textMuted, fontSize: 14),
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List<Widget>.generate(words.length, (index) {
                      final word = words[index];
                      return InputChip(
                        key: ValueKey<String>('remove-translated-word-$index'),
                        label: Text(word),
                        backgroundColor: Sb.surface,
                        side: BorderSide.none,
                        onDeleted: controller.canClearTranslatedUtterance
                            ? () => controller.removeTranslatedWordAt(index)
                            : null,
                      );
                    }),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Sb.gutter, 20, Sb.gutter, 8),
            child: Text(
              controller.backendStatus,
              style: const TextStyle(
                color: Sb.textFaint,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          if (controller.visibleAnalysis != null)
            RecognitionDetails(analysis: controller.visibleAnalysis!),
          if (words.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Sb.gutter, 4, Sb.gutter, 24),
              child: TextButton.icon(
                key: const ValueKey<String>('preview-sign-utterance-json'),
                onPressed: () => _showJsonPreview(context),
                icon: const Icon(Icons.data_object_outlined, size: 18),
                label: const Text('Preview what is sent'),
              ),
            ),
        ],
      ),
    );
  }

  void _showJsonPreview(BuildContext context) {
    final payload = controller.translatedUtterancePreviewJson;
    if (payload == null) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('What is sent'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Camera frames, landmarks, and credentials are never part of this payload.',
                style: TextStyle(
                  color: Sb.textMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Sb.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      child: Text(
                        payload,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.4,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}


/// The per-sign recogniser read-out.
///
/// It is diagnostic rather than conversational, so it lives in the sentence
/// sheet instead of on top of the video.
class RecognitionDetails extends StatelessWidget {
  const RecognitionDetails({super.key, required this.analysis});

  final SignAnalysisResult analysis;

  @override
  Widget build(BuildContext context) {
    final latency = analysis.totalLatencyMs;
    final facts = <String>[
      analysis.status,
      Sb.percent(analysis.confidence),
      if (latency != null) '$latency ms',
      if (analysis.modelVersion.isNotEmpty) analysis.modelVersion,
    ];
    return Container(
      key: const ValueKey<String>('local-asl-model-output'),
      margin: const EdgeInsets.fromLTRB(Sb.gutter, 8, Sb.gutter, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Sb.surface,
        borderRadius: BorderRadius.circular(Sb.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ConfidenceDot(confidence: analysis.confidence),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  analysis.status == 'confident'
                      ? analysis.gestureLabel.toUpperCase()
                      : analysis.caption,
                  key: const ValueKey<String>('local-asl-recognized-word'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            facts.join(' \u00b7 '),
            style: const TextStyle(color: Sb.textMuted, fontSize: 12),
          ),
          if (analysis.hypotheses.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              recognitionAlternativesText(analysis.hypotheses),
              key: const ValueKey<String>('local-asl-alternatives'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Sb.textFaint, fontSize: 12),
            ),
          ],
          if (analysis.detail.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              analysis.detail,
              key: const ValueKey<String>('local-asl-model-input'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Sb.textFaint,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
          if (analysis.glossTrace.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Gloss: ${analysis.glossTrace.join(' \u00b7 ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Sb.textFaint, fontSize: 11),
            ),
          ],
          if (analysis.repairAction != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Action: ${analysis.repairAction}',
              style: const TextStyle(color: Sb.warn, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

String recognitionAlternativesText(List<Map<String, dynamic>> hypotheses) =>
    hypotheses
        .take(3)
        .map((candidate) {
          final label =
              candidate['word']?.toString() ??
              candidate['gloss_id']?.toString() ??
              candidate['label']?.toString() ??
              'unknown';
          final confidence = (candidate['confidence'] as num?)?.toDouble();
          final percent = confidence == null
              ? ''
              : ' ${(confidence * 100).round()}%';
          return '$label$percent';
        })
        .join('  \u00b7  ');
