import 'hand_tracking_models.dart';

/// Tracking health derived by Stage 3 from Harold's raw landmark frame.
enum TrackingStatus { absent, degraded, tracked }

/// Diagnoses why a frame could not be treated as fully tracked.
enum TrackingIssue {
  noLandmarks,
  noHands,
  missingShoulders,
  lowConfidence,
  staleNormalisationAnchor,
  handednessUncertain,
}

/// Identifies the measured source used for a derived landmark.
enum LandmarkSource { mediaPipe, poseWristSubstitution }

/// A derived Cartesian vector used by tracking state and normalisation.
///
/// This type never replaces the raw x/y/z fields supplied by Stage 1/2.
class LandmarkCoordinates {
  const LandmarkCoordinates({required this.x, required this.y, this.z});

  final double x;
  final double y;
  final double? z;

  bool get isFinite => x.isFinite && y.isFinite && (z?.isFinite ?? true);
}

/// Stage 3 state associated with one entry in `LandmarkFrame.hands`.
///
/// [sourceHandIndex] maps this result back to Harold's unchanged hand list.
/// The stable identity and handedness values are derived locally and are not
/// claims that Stage 1/2 supplied a persistent identifier.
class TrackedHandState {
  const TrackedHandState({
    required this.sourceHandIndex,
    required this.trackId,
    required this.stableHandedness,
    required this.rightHandednessRunningAverage,
    required this.handednessObservationCount,
    required this.handednessUncertain,
    this.poseWristSubstituteCoordinates,
    this.poseWristSubstituteVisibility,
  }) : assert(sourceHandIndex >= 0),
       assert(trackId != ''),
       assert(rightHandednessRunningAverage >= 0),
       assert(rightHandednessRunningAverage <= 1),
       assert(handednessObservationCount >= 0),
       assert(
         poseWristSubstituteVisibility == null ||
             (poseWristSubstituteVisibility >= 0 &&
                 poseWristSubstituteVisibility <= 1),
       ),
       assert(
         (poseWristSubstituteCoordinates == null) ==
             (poseWristSubstituteVisibility == null),
       );

  final int sourceHandIndex;
  final String trackId;
  final Handedness stableHandedness;

  /// Track-lifetime probability that this hand is right-handed.
  final double rightHandednessRunningAverage;

  final int handednessObservationCount;
  final bool handednessUncertain;

  /// Optional measured pose wrist used when the matching hand wrist is gated.
  ///
  /// The raw hand landmark remains unchanged; this is an explicit derived
  /// substitute with its own confidence.
  final LandmarkCoordinates? poseWristSubstituteCoordinates;
  final double? poseWristSubstituteVisibility;
}

/// Complete Stage 3 result attached to Harold's unchanged frame.
class TrackingStateResult {
  TrackingStateResult({
    required this.status,
    required this.assessedQuality,
    required List<TrackingIssue> issues,
    required this.canNormalise,
    required this.trackingEpoch,
    required List<TrackedHandState> hands,
  }) : assert(assessedQuality >= 0 && assessedQuality <= 1),
       assert(trackingEpoch >= 0),
       issues = List<TrackingIssue>.unmodifiable(issues),
       hands = List<TrackedHandState>.unmodifiable(hands);

  final TrackingStatus status;

  /// Stage 3's completeness assessment. Harold's trackingConfidence remains
  /// authoritative and is never overwritten with this value.
  final double assessedQuality;

  final List<TrackingIssue> issues;
  final bool canNormalise;
  final int trackingEpoch;
  final List<TrackedHandState> hands;
}

/// Stage 4 values derived for one raw landmark.
///
/// A record may have null coordinate fields when the raw landmark exists but
/// fails confidence or anchor gating. This preserves absence without making
/// up a coordinate.
class NormalisedLandmark {
  const NormalisedLandmark({
    required this.index,
    this.normalisedCoordinates,
    this.velocity,
    this.acceleration,
    this.canonicalWorldCoordinates,
    this.source = LandmarkSource.mediaPipe,
  }) : assert(index >= 0);

  final int index;
  final LandmarkCoordinates? normalisedCoordinates;
  final LandmarkCoordinates? velocity;
  final LandmarkCoordinates? acceleration;
  final LandmarkCoordinates? canonicalWorldCoordinates;
  final LandmarkSource source;
}

/// Stage 4 results for one entry in Harold's unchanged hand list.
class NormalisedHand {
  NormalisedHand({
    required this.sourceHandIndex,
    required this.trackId,
    required List<NormalisedLandmark> landmarks,
  }) : assert(sourceHandIndex >= 0),
       assert(trackId.isNotEmpty),
       landmarks = List<NormalisedLandmark>.unmodifiable(landmarks);

  final int sourceHandIndex;
  final String trackId;
  final List<NormalisedLandmark> landmarks;
}

/// Complete Stage 4 result attached to Harold's unchanged frame.
class NormalisationResult {
  NormalisationResult({
    required this.canNormalise,
    required this.anchorIsStale,
    required List<NormalisedLandmark> poseLandmarks,
    required List<NormalisedLandmark> faceUpperLandmarks,
    required List<NormalisedLandmark> faceMouthLandmarks,
    required List<NormalisedHand> hands,
    this.origin,
    this.scale,
  }) : assert(scale == null || (scale.isFinite && scale > 0)),
       poseLandmarks = List<NormalisedLandmark>.unmodifiable(poseLandmarks),
       faceUpperLandmarks = List<NormalisedLandmark>.unmodifiable(
         faceUpperLandmarks,
       ),
       faceMouthLandmarks = List<NormalisedLandmark>.unmodifiable(
         faceMouthLandmarks,
       ),
       hands = List<NormalisedHand>.unmodifiable(hands);

  final bool canNormalise;
  final LandmarkCoordinates? origin;
  final double? scale;
  final bool anchorIsStale;

  /// Sparse derived pose results keyed by each entry's explicit MediaPipe
  /// pose index.
  final List<NormalisedLandmark> poseLandmarks;

  /// Sparse, separate face groups retaining Harold's explicit point indices.
  final List<NormalisedLandmark> faceUpperLandmarks;
  final List<NormalisedLandmark> faceMouthLandmarks;

  final List<NormalisedHand> hands;
}
