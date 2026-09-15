import '../contracts/gloss_lattice.dart';

/// The only classifier probability accepted by the wire adapter.
///
/// A classifier may keep logits, distances, or raw scores internally, but it
/// must apply its declared calibration before creating this object.
final class CalibratedGlossCandidateInput {
  CalibratedGlossCandidateInput({
    required this.glossId,
    required this.calibratedConfidence,
  }) {
    // Reuse the frozen contract's scalar validation without creating a second
    // interpretation of identifiers or confidence.
    GlossCandidate(glossId: glossId, rank: 1, confidence: calibratedConfidence);
  }

  final String glossId;
  final double calibratedConfidence;
}

/// Minimal Stage 5/6 information needed to create one wire slot.
///
/// [startMs] and [endMs] must already be elapsed milliseconds from the
/// session's monotonic capture-clock origin. The builder deliberately does
/// not convert wall-clock [DateTime] values or assume a frame rate.
final class GlossSlotInput {
  GlossSlotInput({
    required this.slotId,
    required this.startMs,
    required this.endMs,
    required List<CalibratedGlossCandidateInput> candidatesInRankOrder,
    required this.resolvedGlossId,
    required this.provenance,
  }) : candidatesInRankOrder = List<CalibratedGlossCandidateInput>.unmodifiable(
         candidatesInRankOrder,
       ) {
    // Validate this boundary immediately. The final array position replaces
    // the temporary zero index when [GlossLatticeBuilder.build] is called.
    GlossSlot(
      slotIndex: 0,
      slotId: slotId,
      startMs: startMs,
      endMs: endMs,
      candidates: <GlossCandidate>[
        for (var index = 0; index < this.candidatesInRankOrder.length; index++)
          GlossCandidate(
            glossId: this.candidatesInRankOrder[index].glossId,
            rank: index + 1,
            confidence: this.candidatesInRankOrder[index].calibratedConfidence,
          ),
      ],
      resolvedGlossId: resolvedGlossId,
      provenance: provenance,
    );
  }

  final String slotId;
  final int startMs;
  final int endMs;
  final List<CalibratedGlossCandidateInput> candidatesInRankOrder;
  final String? resolvedGlossId;
  final GlossProvenance provenance;
}

/// Converts classified frontend slots into the exact frozen wire contract.
///
/// This class is intentionally not a segmenter or classifier. Esther's stage
/// supplies already segmented time ranges, ranked hypotheses, calibrated
/// probabilities, and any explicit resolution decision. The builder only
/// packages those values and applies the frozen contract's validation.
final class GlossLatticeBuilder {
  GlossLatticeBuilder({
    required this.sessionId,
    required this.language,
    required this.producer,
  }) {
    if (!GlossLatticeContract.isValidUuid(sessionId)) {
      throw const GlossLatticeValidationException(
        'session_id must be a canonical UUID string',
      );
    }
  }

  final String sessionId;
  final GlossLatticeLanguage language;
  final GlossLatticeProducer producer;

  GlossLattice build({
    required int latticeSeq,
    required String utteranceId,
    required int startedAtMs,
    required int endedAtMs,
    required List<GlossSlotInput> slots,
  }) => GlossLattice(
    sessionId: sessionId,
    latticeSeq: latticeSeq,
    utteranceId: utteranceId,
    language: language,
    startedAtMs: startedAtMs,
    endedAtMs: endedAtMs,
    producer: producer,
    slots: <GlossSlot>[
      for (var slotIndex = 0; slotIndex < slots.length; slotIndex += 1)
        GlossSlot(
          slotIndex: slotIndex,
          slotId: slots[slotIndex].slotId,
          startMs: slots[slotIndex].startMs,
          endMs: slots[slotIndex].endMs,
          candidates: <GlossCandidate>[
            for (
              var candidateIndex = 0;
              candidateIndex < slots[slotIndex].candidatesInRankOrder.length;
              candidateIndex += 1
            )
              GlossCandidate(
                glossId: slots[slotIndex]
                    .candidatesInRankOrder[candidateIndex]
                    .glossId,
                rank: candidateIndex + 1,
                confidence: slots[slotIndex]
                    .candidatesInRankOrder[candidateIndex]
                    .calibratedConfidence,
              ),
          ],
          resolvedGlossId: slots[slotIndex].resolvedGlossId,
          provenance: slots[slotIndex].provenance,
        ),
    ],
  );
}
