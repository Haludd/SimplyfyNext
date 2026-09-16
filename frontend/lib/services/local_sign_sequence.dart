import '../models/tracking_models.dart';
import 'sign_analysis_service.dart';

/// Offline stand-in used only to keep the appTesting UI usable before the
/// Stage 5/6 classifier is supplied by the next teammate.
///
/// The real integration path is the Stage 4 frame stream -> classifier seam ->
/// GlossLatticeBuilder -> authenticated WebSocket. This simulator never opens
/// a network connection.
class SimulatedSignSequenceApiClient {
  SimulatedSignSequenceApiClient({SignAnalysisService? analyzer})
    : _analyzer = analyzer ?? SignAnalysisService();

  final SignAnalysisService _analyzer;

  Future<SignAnalysisResult> analyze(SignSequencePayload payload) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    final local = _analyzer.analyze(payload.frames);
    return SignAnalysisResult(
      status: local.status == 'no_signal' ? 'no_signal' : 'simulated',
      gestureLabel: local.gestureLabel,
      caption: local.status == 'no_signal'
          ? local.caption
          : 'Simulated ${payload.language} result · ${local.gestureLabel}.',
      confidence: local.confidence,
      glossTrace: local.glossTrace,
      detail: local.status == 'no_signal'
          ? local.detail
          : '${local.detail} · ${payload.frames.length} frames retained locally; no network request sent.',
    );
  }
}

/// JSON-ready local capture wrapper. It is transport-neutral and remains
/// useful to the next teammate when adapting captured frames to Stage 5/6.
class SignSequencePayload {
  const SignSequencePayload({
    required this.sessionId,
    required this.sequenceId,
    required this.language,
    required this.startedAt,
    required this.endedAt,
    required this.frames,
    required this.lexiconVersion,
  });

  final String sessionId;
  final String sequenceId;
  final String language;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<LandmarkFrame> frames;
  final String lexiconVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'session_id': sessionId,
    'sequence_id': sequenceId,
    'language': language,
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt.toUtc().toIso8601String(),
    'frame_count': frames.length,
    'lexicon_version': lexiconVersion,
    'frames': frames.map((frame) => frame.toJson()).toList(),
  };
}
