import '../adapters/gloss_lattice_builder.dart';
import '../models/tracking_models.dart';

/// Integration seam owned jointly with Stage 5/6.
///
/// This is not a segmentation or classifier implementation. Esther's real
/// service implements this interface: it receives the same Stage 4
/// [LandmarkFrame] and emits completed, calibrated utterance results.
abstract interface class SegmentationClassificationPort {
  Stream<ClassifiedUtteranceOutput> get completedUtterances;

  /// [frame] remains the unchanged LandmarkFrame handoff. The accompanying
  /// value maps the frame's capture time onto the session's monotonic clock;
  /// it is orchestration context, not a replacement frame contract.
  void addNormalisedFrame(
    LandmarkFrame frame, {
    required int sessionTimestampMs,
  });

  /// Drops any open gesture/window state when capture stops or restarts.
  /// This prevents temporal data from two camera runs being joined together.
  Future<void> reset();

  Future<void> close();
}

/// The minimum completed Stage 5/6 result needed by the wire adapter.
///
/// Times are already elapsed milliseconds from the session's monotonic clock.
/// They are never Unix timestamps or frame numbers.
final class ClassifiedUtteranceOutput {
  ClassifiedUtteranceOutput({
    required this.utteranceId,
    required this.startedAtMs,
    required this.endedAtMs,
    required List<GlossSlotInput> slots,
  }) : slots = List<GlossSlotInput>.unmodifiable(slots);

  final String utteranceId;
  final int startedAtMs;
  final int endedAtMs;
  final List<GlossSlotInput> slots;
}
