import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/room_models.dart';
import '../services/asl_label_to_english.dart';
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

class _TranslationPanel extends StatefulWidget {
  const _TranslationPanel({required this.controller, required this.room});

  final AppController controller;
  final RoomSessionController? room;

  @override
  State<_TranslationPanel> createState() => _TranslationPanelState();
}

class _TranslationPanelState extends State<_TranslationPanel> {
  /// How long an accepted sentence stays on screen before it is cleared to
  /// make room for the next one, same as a Reset press would do sooner.
  static const _sentenceDisplayDuration = Duration(seconds: 10);

  /// How long the caption card's accept pulse stays visible.
  static const _acceptGlowDuration = Duration(milliseconds: 650);

  Timer? _dismissTimer;
  String? _shownSentenceId;
  bool _sentenceDismissed = false;

  int _lastWordCount = 0;
  Timer? _glowTimer;
  bool _justAccepted = false;

  AppController get controller => widget.controller;
  RoomSessionController? get room => widget.room;

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _glowTimer?.cancel();
    super.dispose();
  }

  /// Starts a fresh 10-second auto-dismiss window whenever a genuinely new
  /// accepted sentence appears; leaves one already dismissed alone so it
  /// does not reappear on an unrelated rebuild.
  void _trackSentence(RoomMessage? sentence) {
    final isAccepted =
        sentence != null &&
        sentence.status == 'accepted' &&
        (sentence.text?.isNotEmpty ?? false);
    final id = isAccepted ? sentence.messageId : null;
    if (id == _shownSentenceId) return;
    _dismissTimer?.cancel();
    _shownSentenceId = id;
    _sentenceDismissed = false;
    if (id == null) return;
    _dismissTimer = Timer(_sentenceDisplayDuration, () {
      if (!mounted) return;
      setState(() => _sentenceDismissed = true);
      controller.clearCaption();
    });
  }

  /// A brief green pulse whenever the sentence buffer grows, however the new
  /// word was accepted — this is the only feedback now; it replaced a sound
  /// played on every accepted sign.
  void _trackWordCount(int count) {
    if (count > _lastWordCount) {
      _glowTimer?.cancel();
      _justAccepted = true;
      _glowTimer = Timer(_acceptGlowDuration, () {
        if (!mounted) return;
        setState(() => _justAccepted = false);
      });
    }
    _lastWordCount = count;
  }

  void _dismissSentenceNow() {
    _dismissTimer?.cancel();
    _sentenceDismissed = true;
  }

  @override
  Widget build(BuildContext context) {
    final words = controller.translatedWords;
    _trackWordCount(words.length);
    final sending = controller.isUtteranceSubmissionInFlight;
    final rawSentence = _latestOwnSentence(room);
    _trackSentence(rawSentence);
    final sentence = _sentenceDismissed ? null : rawSentence;
    final caption = _caption(words, sentence, sending);
    final analysis = controller.visibleAnalysis;
    final candidates = _topCandidates(analysis);
    final confidence = analysis?.confidence ?? controller.confidence;
    // A captured analysis is itself proof a sign was just read, so it is
    // shown on its own — no separate camera-state check needed.
    final showAnalysisRow = analysis != null;
    final note = _actionableStatus(controller);
    final canSend = controller.canCommitTranslatedUtterance && !sending;
    final canDeleteWord = words.isNotEmpty;
    // Enabled whenever the card is showing anything at all to clear —
    // words in progress, a candidate read-out, or a sentence waiting out
    // its 10-second display window — not just an in-progress word buffer.
    final canReset =
        !controller.hasPendingUtteranceSubmission &&
        (words.isNotEmpty ||
            controller.hasPendingTranslatedWords ||
            analysis != null ||
            sentence != null);

    // Proportional on a phone-sized window (unchanged from before), capped in
    // absolute pixels so the panel does not stretch edge-to-edge and thin out
    // on a full desktop window — that cap is what lets fixed, generous font
    // sizes below stay legible at both sizes instead of needing to shrink to
    // fit a much wider box.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: FractionallySizedBox(
          widthFactor: .93,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _CaptionCard(
                  key: const ValueKey<String>('translated-utterance-buffer'),
                  text: caption.text,
                  muted: caption.muted,
                  canDeleteWord: canDeleteWord,
                  onDeleteWord: () =>
                      controller.removeTranslatedWordAt(words.length - 1),
                  onTap: () => _openWordEditor(context),
                  showAnalysis: showAnalysisRow,
                  candidates: candidates,
                  confidence: confidence,
                  onPick: (candidate) => controller.addHypothesisWord(
                    candidate.label,
                    candidate.confidence,
                  ),
                  justAccepted: _justAccepted,
                ),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 6),
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
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    CameraIconButton(
                      icon: Icons.volume_up_rounded,
                      tooltip: 'Read the sentence aloud',
                      size: 50,
                      onPressed: caption.muted
                          ? null
                          : () => controller.textToSpeech.speak(caption.text),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 56,
                        child: FilledButton.icon(
                          key: const ValueKey<String>(
                            'commit-translated-utterance',
                          ),
                          onPressed: canSend
                              ? controller.commitTranslatedUtterance
                              : null,
                          icon: sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Sb.text,
                                  ),
                                )
                              : const Icon(Icons.arrow_upward_rounded, size: 22),
                          label: Text(
                            sending
                                ? 'Sending…'
                                : 'Send ${words.length} word${words.length == 1 ? '' : 's'}',
                            style: const TextStyle(fontSize: 17),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    CameraIconButton(
                      key: const ValueKey<String>(
                        'reset-translated-utterance',
                      ),
                      icon: Icons.delete_sweep_outlined,
                      tooltip: 'Clear the entire sentence',
                      size: 50,
                      onPressed: canReset
                          ? () {
                              controller.clearCaption();
                              _dismissSentenceNow();
                            }
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
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

/// Muted label text for "Sign:" / "Confidence:" / the empty-candidates dash,
/// now set on the card's own near-solid background rather than on raw video,
/// so it no longer depends on a shadow to stay legible.
const TextStyle _metaStyle = TextStyle(
  color: Sb.textMuted,
  fontSize: 14,
  fontWeight: FontWeight.w600,
);

/// The one caption card: the sentence on top, the sign candidates and
/// confidence underneath, all on one solid, high-contrast surface instead of
/// bare text over the live video. A card this deliberately opaque is no
/// longer really "glass" — legibility against a busy video background won by
/// design here over the earlier translucent look.
class _CaptionCard extends StatelessWidget {
  const _CaptionCard({
    super.key,
    required this.text,
    required this.muted,
    required this.canDeleteWord,
    required this.onDeleteWord,
    required this.onTap,
    required this.showAnalysis,
    required this.candidates,
    required this.confidence,
    required this.onPick,
    required this.justAccepted,
  });

  final String text;
  final bool muted;
  final bool canDeleteWord;
  final VoidCallback onDeleteWord;
  final VoidCallback onTap;
  final bool showAnalysis;
  final List<_Candidate> candidates;
  final double confidence;
  final ValueChanged<_Candidate> onPick;

  /// True for a brief moment right after a word is accepted into the
  /// sentence — the card pulses pastel green instead of playing a sound.
  final bool justAccepted;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOut,
    decoration: BoxDecoration(
      color: justAccepted
          ? Color.lerp(Colors.white, Sb.good, .24)
          : Colors.white.withValues(alpha: .96),
      borderRadius: BorderRadius.circular(Sb.radiusLarge),
      border: Border.all(
        color: justAccepted ? Sb.good.withValues(alpha: .6) : Sb.border,
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: .22),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Sb.radiusLarge),
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 10, showAnalysis ? 12 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      text,
                      key: const ValueKey<String>('live-translation-text'),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 21,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                        color: muted ? Sb.textMuted : Sb.text,
                      ),
                    ),
                  ),
                  if (canDeleteWord)
                    IconButton(
                      key: const ValueKey<String>(
                        'delete-last-translated-word',
                      ),
                      tooltip: 'Remove the last word',
                      onPressed: onDeleteWord,
                      icon: const Icon(
                        Icons.backspace_outlined,
                        size: 22,
                        color: Sb.textMuted,
                      ),
                    )
                  else
                    const SizedBox(width: 8),
                ],
              ),
              if (showAnalysis) ...<Widget>[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Divider(height: 1, color: Sb.border),
                ),
                _AnalysisRow(
                  candidates: candidates,
                  confidence: confidence,
                  onPick: onPick,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// One raw model hypothesis, with the contract-safe English text it would add
/// to the sentence if picked.
class _Candidate {
  const _Candidate({
    required this.label,
    required this.confidence,
    required this.display,
  });

  /// The raw ASL gloss label, e.g. `thankyou`. Sent to
  /// [AppController.addHypothesisWord], which re-translates it.
  final String label;
  final double confidence;

  /// The English word(s) shown on the chip, e.g. `THANK YOU`.
  final String display;
}

const AslLabelToEnglish _labelTranslator = AslLabelToEnglish();

/// The top 3 recognition hypotheses for the sign currently on screen, highest
/// confidence first.
List<_Candidate> _topCandidates(SignAnalysisResult? analysis) {
  final hypotheses = analysis?.hypotheses ?? const <Map<String, dynamic>>[];
  final sorted = List<Map<String, dynamic>>.of(hypotheses)
    ..sort((a, b) {
      final confidenceA = (a['confidence'] as num?)?.toDouble() ?? 0;
      final confidenceB = (b['confidence'] as num?)?.toDouble() ?? 0;
      return confidenceB.compareTo(confidenceA);
    });
  final candidates = <_Candidate>[];
  for (final hypothesis in sorted) {
    final label = hypothesis['word']?.toString();
    if (label == null || label.isEmpty) continue;
    final confidence = (hypothesis['confidence'] as num?)?.toDouble() ?? 0;
    candidates.add(
      _Candidate(
        label: label,
        confidence: confidence,
        display: _candidateDisplay(label),
      ),
    );
    if (candidates.length == 3) break;
  }
  return candidates;
}

String _candidateDisplay(String label) {
  try {
    return _labelTranslator.translateLabel(label).join(' ');
  } on ArgumentError {
    return label.toUpperCase();
  }
}

/// "Sign:" and "Confidence:" on one line — the recognised candidates for the
/// current sign on the left (tap one to add it), the confidence of the top
/// candidate on the right.
class _AnalysisRow extends StatelessWidget {
  const _AnalysisRow({
    required this.candidates,
    required this.confidence,
    required this.onPick,
  });

  final List<_Candidate> candidates;
  final double confidence;
  final ValueChanged<_Candidate> onPick;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: <Widget>[
      const Text('Sign:', style: _metaStyle),
      const SizedBox(width: 8),
      Expanded(
        child: candidates.isEmpty
            ? const Text('—', style: _metaStyle)
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    for (var i = 0; i < candidates.length; i += 1) ...<Widget>[
                      if (i > 0) const SizedBox(width: 7),
                      _CandidateChip(
                        candidate: candidates[i],
                        // Candidates are already sorted by confidence, so
                        // rank 0 is always the most likely sign.
                        isTopRank: i == 0,
                        onTap: () => onPick(candidates[i]),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      const SizedBox(width: 10),
      ConfidenceDot(confidence: confidence, size: 11),
      const SizedBox(width: 6),
      Text('Confidence: ${Sb.percent(confidence)}', style: _metaStyle),
    ],
  );
}

class _CandidateChip extends StatelessWidget {
  const _CandidateChip({
    required this.candidate,
    required this.isTopRank,
    required this.onTap,
  });

  final _Candidate candidate;

  /// The single most likely sign gets the main accent so it reads as the
  /// default choice; the other candidates get a light grey — a step up from
  /// the white card behind them, but deliberately not accented, so they
  /// stay clearly secondary to it.
  final bool isTopRank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: isTopRank ? Sb.primary : Sb.surfaceStrong,
    borderRadius: BorderRadius.circular(999),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      key: ValueKey<String>('sign-candidate-${candidate.label}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          '${candidate.display} ${Sb.percent(candidate.confidence)}',
          style: const TextStyle(
            color: Sb.text,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    ),
  );
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
            facts.join(' · '),
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
              'Gloss: ${analysis.glossTrace.join(' · ')}',
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
        .join('  ·  ');
