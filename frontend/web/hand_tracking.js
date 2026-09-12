import {
  beginAslCapture,
  finishAslCapture,
  ingestAslFrame,
  prepareAslRecognizer,
  resetAslCapture,
} from './asl_recognizer.js?v=20250911-model-aligned-adaptation';

// The bundled ASL model was trained with MediaPipe Holistic, not independent
// Hand/Pose/Face Task models. The legacy browser Holistic solution emits the
// identical 468-face + 33-pose + left/right-21-hand topology in one pass.
const HOLISTIC_CDN_BASE =
  'https://cdn.jsdelivr.net/npm/@mediapipe/holistic@0.5.1675471629';

// These are the useful upper-body points from MediaPipe Pose. The model still
// sees the complete pose internally; only this small, stable subset crosses
// the application boundary.
const POSE_LANDMARKS = [
  [0, 'nose'],
  [11, 'left_shoulder'],
  [12, 'right_shoulder'],
  [13, 'left_elbow'],
  [14, 'right_elbow'],
  [15, 'left_wrist'],
  [16, 'right_wrist'],
  [23, 'left_hip'],
  [24, 'right_hip'],
  [25, 'left_knee'],
  [26, 'right_knee'],
];

// Face Mesh indices for the upper-face and mouth regions. The remaining face
// mesh points stay inside MediaPipe and are deliberately not sent to the
// classifier.
const FACE_UPPER_LANDMARKS = [
  [33, 'left_eye_outer'],
  [133, 'left_eye_inner'],
  [160, 'left_eye_upper'],
  [159, 'left_eye_center_upper'],
  [158, 'left_eye_center_lower'],
  [157, 'left_eye_lower'],
  [173, 'left_eye_inner_lower'],
  [362, 'right_eye_outer'],
  [263, 'right_eye_inner'],
  [387, 'right_eye_upper'],
  [386, 'right_eye_center_upper'],
  [385, 'right_eye_center_lower'],
  [384, 'right_eye_lower'],
  [398, 'right_eye_inner_lower'],
  [70, 'left_brow_outer'],
  [63, 'left_brow_inner'],
  [105, 'left_brow_center'],
  [66, 'left_brow_upper'],
  [107, 'left_brow_lower'],
  [336, 'right_brow_outer'],
  [296, 'right_brow_inner'],
  [334, 'right_brow_center'],
  [293, 'right_brow_upper'],
  [300, 'right_brow_lower'],
];

const FACE_MOUTH_LANDMARKS = [
  [61, 'mouth_left'],
  [291, 'mouth_right'],
  [0, 'mouth_top_center'],
  [17, 'mouth_bottom_center'],
  [13, 'upper_lip_center'],
  [14, 'lower_lip_center'],
  [78, 'mouth_left_inner'],
  [308, 'mouth_right_inner'],
  [82, 'upper_lip_left'],
  [312, 'upper_lip_right'],
  [95, 'lower_lip_left'],
  [324, 'lower_lip_right'],
];
// The integrated architecture keeps every camera image on the device. The
// old opt-in DeepFace upload is deliberately disabled; only the compact
// GlossLattice may cross the frontend/backend boundary.
const DEEPFACE_API_URL = '';
const DEEPFACE_INTERVAL_MS = 1200;
const queryTrackingFps = Number(
  new URLSearchParams(globalThis.location.search).get('tracking_fps'),
);
const TRACKING_FPS = Number.isFinite(queryTrackingFps)
  ? Math.min(60, Math.max(18, queryTrackingFps))
  : 30;
const DETECTION_INTERVAL_MS = 1000 / TRACKING_FPS;
const FLUTTER_EVENT_FPS = Math.min(18, TRACKING_FPS);
const FLUTTER_EVENT_INTERVAL_MS = 1000 / FLUTTER_EVENT_FPS;
const POINT_QUALITY_CANVAS_WIDTH = 192;
const POINT_QUALITY_INTERVAL_MS = 100;
const SUBJECT_MATCH_DISTANCE = 0.32;
const SUBJECT_FACE_MATCH_DISTANCE = 0.25;
const SUBJECT_ACQUIRE_STABLE_FRAMES = 8;
// If two people are similarly close to the locked subject, do not guess.
// Holding the last lock is safer for sign-language capture than switching.
const SUBJECT_AMBIGUITY_MARGIN = 0.08;
// The first stable person owns this tracking session. A refresh/restart is
// required to deliberately select a different person; this prevents a
// newcomer from silently replacing the signer during a sentence.
// Use torso/head points for identity matching. Wrists and elbows are omitted
// because they are expected to move quickly during signing.
const SUBJECT_ANCHOR_INDICES = [0, 11, 12, 23, 24];

// MediaPipe gives us 21 points for each detected hand. Keep the five fingers
// as named groups so the app can report the quality of each finger instead of
// only saying "the hand was detected".
const FINGER_DEFINITIONS = {
  thumb: [1, 2, 3, 4],
  index: [5, 6, 7, 8],
  middle: [9, 10, 11, 12],
  ring: [13, 14, 15, 16],
  pinky: [17, 18, 19, 20],
};
const FINGER_HISTORY_LENGTH = 8;

let holistic;
let video;
let stream;
let animationFrame;
let started = false;
let deepFaceEmotion;
let deepFaceRequestInFlight = false;
let lastDeepFaceRequestAt = 0;
let deepFaceWarningShown = false;
let deepFaceSubjectGeneration = 0;
let emotionCanvas;
let emotionContext;
let pointQualityCanvas;
let pointQualityContext;
let pointQualityPixels;
let pointQualityWidth = 0;
let pointQualityHeight = 0;
let lastPointQualityAt = 0;
let lastProcessedAt = 0;
let lastFlutterFrameAt = 0;
let detectionInProgress = false;
let trackingFrameErrorShown = false;
let trackingLoopFrameCount = 0;
let trackingLoopStartedAt = 0;
let trackingLoopLastLogAt = 0;
let subjectTrack;
let subjectAcquire;
let subjectReferenceIdentity;
let fingerQualityHistory = {
  left: {},
  right: {},
  unknown: {},
};

function cameraElements() {
  return Array.from(
    document.querySelectorAll('[data-signbridge-camera]'),
  );
}

function isVisibleCameraElement(element) {
  const style = globalThis.getComputedStyle(element);
  const rect = element.getBoundingClientRect();
  return (
    style.display !== 'none' &&
    style.visibility !== 'hidden' &&
    style.opacity !== '0' &&
    rect.width > 0 &&
    rect.height > 0
  );
}

function visibleCameraElement() {
  const elements = cameraElements();
  return (
    elements.find((element) => isVisibleCameraElement(element)) ||
    elements[0]
  );
}

function syncVisibleCameraElement() {
  if (!stream) return;
  const nextVideo = visibleCameraElement();
  if (!nextVideo || nextVideo === video) return;

  if (video) video.srcObject = null;
  video = nextVideo;
  video.srcObject = stream;
  video.muted = true;
  video.playsInline = true;
  void video.play().catch((error) => {
    console.warn('Unable to resume the visible camera preview.', error);
  });
}

function clamp01(value) {
  return Math.min(1, Math.max(0, Number(value) || 0));
}

// MediaPipe's hand landmarks do not expose a visibility score for every
// joint. Build a small low-resolution copy of the current frame and measure
// local high-frequency detail around each point. A blurred or covered patch
// has less detail, so its point confidence is reduced. This is a quality
// estimate, not a guarantee that the anatomy is visible.
function preparePointQualityFrame() {
  const now = performance.now();
  if (
    pointQualityPixels &&
    now - lastPointQualityAt < POINT_QUALITY_INTERVAL_MS
  ) {
    return;
  }
  pointQualityPixels = null;
  if (
    !video ||
    video.readyState < 2 ||
    !video.videoWidth ||
    !video.videoHeight
  ) {
    return;
  }
  try {
    pointQualityCanvas ??= document.createElement('canvas');
    pointQualityWidth = POINT_QUALITY_CANVAS_WIDTH;
    pointQualityHeight = Math.max(
      1,
      Math.round(
        pointQualityWidth * (video.videoHeight / video.videoWidth),
      ),
    );
    pointQualityCanvas.width = pointQualityWidth;
    pointQualityCanvas.height = pointQualityHeight;
    pointQualityContext ??= pointQualityCanvas.getContext('2d', {
      willReadFrequently: true,
    });
    if (!pointQualityContext) return;
    pointQualityContext.drawImage(
      video,
      0,
      0,
      pointQualityWidth,
      pointQualityHeight,
    );
    pointQualityPixels = pointQualityContext.getImageData(
      0,
      0,
      pointQualityWidth,
      pointQualityHeight,
    ).data;
    lastPointQualityAt = now;
  } catch (error) {
    // Camera/CORS/browser canvas restrictions should not stop tracking. The
    // fallback below uses the detector's hand-level confidence only.
    pointQualityPixels = null;
  }
}

function pixelLumaAt(x, y) {
  if (!pointQualityPixels) return 128;
  const pixelX = Math.min(pointQualityWidth - 1, Math.max(0, Math.round(x)));
  const pixelY = Math.min(pointQualityHeight - 1, Math.max(0, Math.round(y)));
  const offset = (pixelY * pointQualityWidth + pixelX) * 4;
  return (
    pointQualityPixels[offset] * 0.299 +
    pointQualityPixels[offset + 1] * 0.587 +
    pointQualityPixels[offset + 2] * 0.114
  );
}

function localImageConfidence(point) {
  if (!pointQualityPixels || !validHandPoint(point)) return 0.85;
  const centerX = clamp01(point.x) * (pointQualityWidth - 1);
  const centerY = clamp01(point.y) * (pointQualityHeight - 1);
  let detail = 0;
  let samples = 0;
  for (let y = -2; y <= 2; y += 1) {
    for (let x = -2; x <= 2; x += 1) {
      const horizontal = Math.abs(
        pixelLumaAt(centerX + x + 1, centerY + y) -
          pixelLumaAt(centerX + x - 1, centerY + y),
      );
      const vertical = Math.abs(
        pixelLumaAt(centerX + x, centerY + y + 1) -
          pixelLumaAt(centerX + x, centerY + y - 1),
      );
      detail += horizontal + vertical;
      samples += 1;
    }
  }
  const averageDetail = detail / Math.max(1, samples);
  const sharpness = clamp01((averageDetail - 3) / 24);
  return 0.25 + sharpness * 0.75;
}

function pointConfidence(point, modelConfidence) {
  const detectorConfidence = clamp01(modelConfidence);
  const imageConfidence = localImageConfidence(point);
  // The detector remains the primary signal, while local image quality can
  // lower confidence when this exact part of the frame is blurred/covered.
  return clamp01(
    detectorConfidence * (0.65 + imageConfidence * 0.35),
  );
}

function posePointToJson(point, index, name) {
  if (!point) return null;
  const modelConfidence = point.visibility ?? point.presence ?? 0;
  const confidence = pointConfidence(point, modelConfidence);
  return {
    index,
    name,
    x: point.x,
    y: point.y,
    z: point.z ?? 0,
    visibility: confidence,
    presence: confidence,
  };
}

function facePointToJson(point, index, name) {
  if (!point) return null;
  const confidence = pointConfidence(point, 0.75);
  return {
    index,
    name,
    x: point.x,
    y: point.y,
    z: point.z ?? 0,
    visibility: confidence,
  };
}

function curatedLandmarks(allLandmarks, definitions, converter) {
  return definitions
    .map(([index, name]) => converter(allLandmarks[index], index, name))
    .filter((point) => point !== null);
}

function poseCandidate(landmarks) {
  const visible = landmarks.filter(
    (point) => (point.visibility ?? point.presence ?? 0) >= 0.35,
  );
  if (visible.length < 4) return null;
  const xs = visible.map((point) => point.x);
  const ys = visible.map((point) => point.y);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const centerX = (minX + maxX) / 2;
  const centerY = (minY + maxY) / 2;
  const area = Math.max(0.04, maxX - minX) * Math.max(0.08, maxY - minY);
  const centrality = Math.max(
    0,
    1 - Math.hypot(centerX - 0.5, centerY - 0.5) / 0.71,
  );
  const nose = landmarks[0];
  // Build the identity shape from torso points only. Hands, elbows, and
  // knees move during signing and must not make the signer look like a new
  // person.
  const torso = [11, 12, 23, 24]
    .map((index) => landmarks[index])
    .filter(
      (point) => point && (point.visibility ?? point.presence ?? 0) >= 0.35,
    );
  const torsoCenterX = torso.length
    ? torso.reduce((sum, point) => sum + point.x, 0) / torso.length
    : centerX;
  const torsoCenterY = torso.length
    ? torso.reduce((sum, point) => sum + point.y, 0) / torso.length
    : centerY;
  const torsoXs = torso.map((point) => point.x);
  const torsoYs = torso.map((point) => point.y);
  const identityWidth = Math.max(
    0.12,
    (torsoXs.length ? Math.max(...torsoXs) - Math.min(...torsoXs) : 0),
  );
  const identityHeight = Math.max(
    0.18,
    (torsoYs.length ? Math.max(...torsoYs) - Math.min(...torsoYs) : 0),
  );
  const identityAnchors = SUBJECT_ANCHOR_INDICES.map((index) => {
    const point = landmarks[index];
    return point &&
      (point.visibility ?? point.presence ?? 0) >= 0.35
      ? {
          index,
          x: (point.x - torsoCenterX) / identityWidth,
          y: (point.y - torsoCenterY) / identityHeight,
        }
      : null;
  }).filter((point) => point !== null);
  if (identityAnchors.length < 3) return null;
  return {
    landmarks,
    minX,
    maxX,
    minY,
    maxY,
    centerX,
    centerY,
    faceX: nose?.x ?? centerX,
    faceY: nose?.y ?? Math.max(0, centerY - 0.25),
    area,
    score: area * (0.65 + centrality * 0.35),
    identityAnchors,
    anchors: SUBJECT_ANCHOR_INDICES.map((index) => {
      const point = landmarks[index];
      return point &&
        (point.visibility ?? point.presence ?? 0) >= 0.35
        ? {index, x: point.x, y: point.y}
        : null;
    }).filter((point) => point !== null),
  };
}

function lockSubject(candidate) {
  subjectReferenceIdentity ??= candidate.identityAnchors ?? [];
  subjectTrack = {
    ...candidate,
    identityAnchors: subjectReferenceIdentity,
    locked: true,
    visible: true,
    missingFrames: 0,
    missingSinceMs: null,
  };
  return subjectTrack;
}

function identityDistance(candidate, reference) {
  const candidateAnchors = candidate?.identityAnchors ?? [];
  const referenceAnchors = reference ?? [];
  const distances = [];
  for (const previous of referenceAnchors) {
    const current = candidateAnchors.find((point) => point.index === previous.index);
    if (!current) continue;
    distances.push(Math.hypot(current.x - previous.x, current.y - previous.y));
  }
  if (distances.length < 3) return Number.POSITIVE_INFINITY;
  return distances.reduce((sum, distance) => sum + distance, 0) / distances.length;
}

function anchorDistance(first, second) {
  const firstAnchors = first?.anchors ?? [];
  const secondAnchors = second?.anchors ?? [];
  const distances = [];
  for (const previous of firstAnchors) {
    const current = secondAnchors.find((point) => point.index === previous.index);
    if (!current) continue;
    distances.push(Math.hypot(current.x - previous.x, current.y - previous.y));
  }
  if (distances.length < 3) return Number.POSITIVE_INFINITY;
  return distances.reduce((sum, distance) => sum + distance, 0) / distances.length;
}

function acquireStableSubject(candidates) {
  const candidate = candidates[0];
  if (!subjectAcquire) {
    subjectAcquire = {
      ...candidate,
      stableFrames: 1,
    };
  } else {
    const centerDistance = Math.hypot(
      candidate.centerX - subjectAcquire.centerX,
      candidate.centerY - subjectAcquire.centerY,
    );
    const bodyDistance = anchorDistance(candidate, subjectAcquire);
    if (centerDistance <= 0.18 && bodyDistance <= 0.16) {
      subjectAcquire = {
        ...candidate,
        stableFrames: subjectAcquire.stableFrames + 1,
      };
    } else {
      // A different person or an unstable detection appeared before the lock.
      // Start the acquisition window again instead of choosing immediately.
      subjectAcquire = {
        ...candidate,
        stableFrames: 1,
      };
    }
  }

  if (subjectAcquire.stableFrames < SUBJECT_ACQUIRE_STABLE_FRAMES) {
    return null;
  }
  const locked = lockSubject(subjectAcquire);
  subjectAcquire = null;
  return locked;
}

function holdLockedSubject() {
  if (!subjectTrack) return null;
  const now = performance.now();
  const missingSinceMs = subjectTrack.missingSinceMs ?? now;
  subjectTrack = {
    ...subjectTrack,
    // Keep the lock identity, but do not reuse stale landmarks as current
    // data. This prevents a new person from being accepted after an occlusion.
    visible: false,
    missingSinceMs,
    // Keep counting for diagnostics. The old identity is intentionally held
    // until the user presses the refresh/restart control.
    missingFrames: Math.min(10_000, subjectTrack.missingFrames + 1),
  };
  return subjectTrack;
}

function subjectMatchScore(candidate) {
  if (!subjectTrack) return Number.POSITIVE_INFINITY;
  const identity = identityDistance(candidate, subjectReferenceIdentity);
  // Pose landmarks do not provide a true biometric ID, so use a stable
  // torso/head shape as an additional guard against a nearby newcomer.
  if (!Number.isFinite(identity) || identity > 0.34) {
    return Number.POSITIVE_INFINITY;
  }
  const centerDistance = Math.hypot(
    candidate.centerX - subjectTrack.centerX,
    candidate.centerY - subjectTrack.centerY,
  );
  if (centerDistance > SUBJECT_MATCH_DISTANCE) return Number.POSITIVE_INFINITY;

  const previousAnchors = subjectTrack.anchors ?? [];
  const currentAnchors = candidate.anchors ?? [];
  const distances = [];
  for (const previous of previousAnchors) {
    const current = currentAnchors.find((point) => point.index === previous.index);
    if (!current) continue;
    distances.push(Math.hypot(current.x - previous.x, current.y - previous.y));
  }
  // A body-anchor match makes a nearby newcomer much less likely to replace
  // the locked signer when MediaPipe briefly loses one pose.
  if (distances.length < 3) return Number.POSITIVE_INFINITY;
  const averageDistance =
    distances.reduce((sum, distance) => sum + distance, 0) / distances.length;
  if (averageDistance > 0.14 || Math.max(...distances) > 0.28) {
    return Number.POSITIVE_INFINITY;
  }
  // Lower is a better continuation of the locked subject. This lets the
  // tracker choose the correct candidate even if another person is closer to
  // the old centre for one frame.
  return identity * 0.65 + averageDistance + centerDistance * 0.35;
}

function selectSubjectPose(poseResult) {
  const candidates = (poseResult?.landmarks ?? [])
    .map(poseCandidate)
    .filter((candidate) => candidate !== null);
  candidates.sort((first, second) => second.score - first.score);
  if (candidates.length === 0) {
    // A subject lock lasts until the tracking session is stopped/restarted.
    // Do not promote a person who enters later to the active subject.
    return holdLockedSubject();
  }

  // The first stable subject becomes the lock. Waiting for several consistent
  // frames avoids choosing a transient detection during camera startup.
  if (!subjectTrack) return acquireStableSubject(candidates);

  const matches = candidates
    .map((candidate) => ({
      candidate,
      score: subjectMatchScore(candidate),
    }))
    .filter((entry) => Number.isFinite(entry.score))
    .sort((first, second) => first.score - second.score);
  if (matches.length > 0) {
    const best = matches[0];
    const secondBest = matches[1];
    if (
      secondBest &&
      secondBest.score - best.score < SUBJECT_AMBIGUITY_MARGIN
    ) {
      // Do not allow a nearby person to win by a tiny score difference.
      return holdLockedSubject();
    }
    return lockSubject(best.candidate);
  }

  // No candidate is close enough to the locked subject. Keep the lock and
  // ignore every other person until the user deliberately refreshes tracking.
  return holdLockedSubject();
}

function selectSubjectFace(faceResult, subject) {
  const candidates = faceResult?.faceLandmarks ?? [];
  if (candidates.length === 0 || !subject || subject.visible === false) return [];
  const targetX = subject?.faceX ?? 0.5;
  const targetY = subject?.faceY ?? 0.35;
  const nearest = candidates.reduce((best, candidate) => {
    const points = candidate.filter((point) => point != null);
    if (points.length === 0) return best;
    const centerX = points.reduce((sum, point) => sum + point.x, 0) / points.length;
    const centerY = points.reduce((sum, point) => sum + point.y, 0) / points.length;
    const distance = Math.hypot(centerX - targetX, centerY - targetY);
    if (!best || distance < best.distance) return {points, distance};
    return best;
  }, null);
  return nearest && nearest.distance <= SUBJECT_FACE_MATCH_DISTANCE
    ? nearest.points
    : [];
}

function handBelongsToSubject(hand, subject) {
  // Do not emit hands before the pose lock exists. Otherwise another person's
  // hands could enter the stream during the few frames before pose detection.
  // Keep using the locked subject's last known body region when pose briefly
  // drops out. This accepts real hand points without inventing any points or
  // allowing a newcomer to replace the lock.
  if (!subject || !hand?.landmarks?.[0]) return false;
  const wrist = hand.landmarks[0];
  const subjectWidth = Math.max(0.12, subject.maxX - subject.minX);
  const subjectHeight = Math.max(0.2, subject.maxY - subject.minY);
  const marginX = Math.max(0.16, subjectWidth * 0.4);
  const marginY = Math.max(0.16, subjectHeight * 0.18);
  const insideBodyRegion = (
    wrist.x >= subject.minX - marginX &&
    wrist.x <= subject.maxX + marginX &&
    wrist.y >= subject.minY - marginY &&
    wrist.y <= subject.maxY + marginY
  );
  const poseWrists = [15, 16]
    .map((index) => subject.landmarks?.[index])
    .filter(
      (point) => point && (point.visibility ?? point.presence ?? 0) >= 0.35,
    );
  const nearestPoseWristDistance = poseWrists.length
    ? Math.min(
        ...poseWrists.map((point) =>
          Math.hypot(wrist.x - point.x, wrist.y - point.y),
        ),
      )
    : Number.POSITIVE_INFINITY;
  // Use either pose wrist, not the same-side wrist. During a crossed-arm sign
  // the left hand can be beside the right pose wrist and vice versa.
  return (
    insideBodyRegion ||
    nearestPoseWristDistance <= Math.max(0.28, subjectWidth * 1.1)
  );
}

function validHandPoint(point) {
  return (
    point &&
    Number.isFinite(point.x) &&
    Number.isFinite(point.y) &&
    Number.isFinite(point.z ?? 0)
  );
}

function correctedHandedness(categoryName, source = 'tasks') {
  const raw = categoryName?.toLowerCase();
  // Holistic already exposes the same named left/right result streams as the
  // Python Holistic pipeline used to train this model. Do not flip them.
  if (source === 'holistic') {
    return raw === 'left' || raw === 'right' ? raw : 'unknown';
  }
  // CSS mirrors the preview only; the video pixels delivered to MediaPipe are
  // not mirrored. MediaPipe's hand labels assume mirrored selfie input, so
  // swap them to restore the person-relative left/right order required by the
  // upstream Holistic-trained ASL model.
  if (raw === 'left') return 'right';
  if (raw === 'right') return 'left';
  return 'unknown';
}

function distanceBetweenPoints(first, second) {
  return Math.hypot(
    first.x - second.x,
    first.y - second.y,
    (first.z ?? 0) - (second.z ?? 0),
  );
}

function palmScale(landmarks) {
  const wrist = landmarks[0];
  const palmPoints = [landmarks[5], landmarks[9], landmarks[17]].filter(
    validHandPoint,
  );
  if (!validHandPoint(wrist) || palmPoints.length === 0) return 0.1;
  const average =
    palmPoints.reduce(
      (sum, point) => sum + distanceBetweenPoints(wrist, point),
      0,
    ) / palmPoints.length;
  return Math.max(0.04, average);
}

function fingerObservation(landmarks, indices, handConfidence) {
  const points = indices.map((index) => landmarks[index]);
  if (points.some((point) => !validHandPoint(point))) {
    return {score: 0, status: 'not_visible'};
  }

  const scale = palmScale(landmarks);
  const segmentLengths = points.slice(1).map((point, index) =>
    distanceBetweenPoints(point, points[index]),
  );
  const minimumSegment = scale * 0.012;
  const maximumSegment = scale * 1.4;
  const plausibleGeometry = segmentLengths.every(
    (length) => length >= minimumSegment && length <= maximumSegment,
  );
  const pointVisibility = points.reduce(
    (minimum, point) => Math.min(minimum, point.visibility ?? 1),
    1,
  );
  const confidence = Math.min(1, Math.max(0, Number(handConfidence) || 0));
  const geometryScore = plausibleGeometry ? 1 : 0.25;
  const score = confidence * 0.65 + pointVisibility * 0.15 + geometryScore * 0.2;
  const status = score >= 0.72
    ? 'observed'
    : score >= 0.4
      ? 'uncertain'
      : 'not_visible';
  return {score, status};
}

function fingerStatusesForHand(landmarks, handConfidence, handedness) {
  const side = ['left', 'right'].includes(handedness) ? handedness : 'unknown';
  const history = fingerQualityHistory[side] ?? {};
  const statuses = {};
  for (const [finger, indices] of Object.entries(FINGER_DEFINITIONS)) {
    const observation = fingerObservation(landmarks, indices, handConfidence);
    const values = history[finger] ?? [];
    values.push(observation.score);
    history[finger] = values.slice(-FINGER_HISTORY_LENGTH);
    const average =
      history[finger].reduce((sum, value) => sum + value, 0) /
      history[finger].length;
    const status = average >= 0.72
      ? 'observed'
      : average >= 0.4
        ? 'uncertain'
        : 'not_visible';
    statuses[finger] = {
      status,
      confidence: Number(average.toFixed(3)),
      evidence_frames: history[finger].length,
    };
  }
  fingerQualityHistory[side] = history;
  return statuses;
}

function subjectFaceCrop(faceLandmarks, subject, sourceWidth, sourceHeight) {
  const points = (faceLandmarks ?? []).filter((point) => point != null);
  let faceMinX;
  let faceMaxX;
  let faceMinY;
  let faceMaxY;
  if (points.length >= 4) {
    const xs = points.map((point) => point.x);
    const ys = points.map((point) => point.y);
    faceMinX = Math.max(0, Math.min(...xs));
    faceMaxX = Math.min(1, Math.max(...xs));
    faceMinY = Math.max(0, Math.min(...ys));
    faceMaxY = Math.min(1, Math.max(...ys));
  } else if (subject?.faceX != null && subject?.faceY != null) {
    // If the optional Face Landmarker is unavailable, use the locked pose's
    // nose as a subject-only crop rather than sending the whole camera frame.
    const estimatedWidth = Math.max(
      0.12,
      Math.min(0.5, (subject.maxX - subject.minX) * 0.45),
    );
    const estimatedHeight = estimatedWidth * 1.25;
    faceMinX = subject.faceX - estimatedWidth / 2;
    faceMaxX = subject.faceX + estimatedWidth / 2;
    faceMinY = subject.faceY - estimatedHeight * 0.42;
    faceMaxY = subject.faceY + estimatedHeight * 0.58;
  } else {
    return null;
  }
  const faceWidth = Math.max(0.02, faceMaxX - faceMinX);
  const faceHeight = Math.max(0.02, faceMaxY - faceMinY);
  const paddingX = Math.max(0.06, faceWidth * 0.45);
  const paddingY = Math.max(0.08, faceHeight * 0.65);
  const minX = Math.max(0, faceMinX - paddingX);
  const maxX = Math.min(1, faceMaxX + paddingX);
  const minY = Math.max(0, faceMinY - paddingY);
  const maxY = Math.min(1, faceMaxY + paddingY);
  return {
    x: minX * sourceWidth,
    y: minY * sourceHeight,
    width: Math.max(1, (maxX - minX) * sourceWidth),
    height: Math.max(1, (maxY - minY) * sourceHeight),
  };
}

async function requestDeepFaceEmotion(subject, faceLandmarks) {
  if (
    !DEEPFACE_API_URL ||
    !video ||
    video.readyState < 2 ||
    !subject ||
    subject.visible === false ||
    deepFaceRequestInFlight
  ) {
    return;
  }

  const now = performance.now();
  if (now - lastDeepFaceRequestAt < DEEPFACE_INTERVAL_MS) return;
  lastDeepFaceRequestAt = now;
  deepFaceRequestInFlight = true;
  const subjectGeneration = deepFaceSubjectGeneration;

  try {
    if (!emotionCanvas) {
      emotionCanvas = document.createElement('canvas');
      emotionContext = emotionCanvas.getContext('2d');
    }
    const sourceWidth = video.videoWidth || 640;
    const sourceHeight = video.videoHeight || 480;
    const crop = subjectFaceCrop(
      faceLandmarks,
      subject,
      sourceWidth,
      sourceHeight,
    );
    if (!crop) return;
    const scale = Math.min(1, 480 / crop.width);
    emotionCanvas.width = Math.max(1, Math.round(crop.width * scale));
    emotionCanvas.height = Math.max(1, Math.round(crop.height * scale));
    emotionContext.drawImage(
      video,
      crop.x,
      crop.y,
      crop.width,
      crop.height,
      0,
      0,
      emotionCanvas.width,
      emotionCanvas.height,
    );
    const blob = await new Promise((resolve) =>
      emotionCanvas.toBlob(resolve, 'image/jpeg', 0.68),
    );
    if (!blob) return;

    const controller = new AbortController();
    const requestTimeout = setTimeout(() => controller.abort(), 5000);
    let response;
    try {
      response = await fetch(DEEPFACE_API_URL, {
        method: 'POST',
        headers: {'Content-Type': 'image/jpeg'},
        body: blob,
        signal: controller.signal,
      });
    } finally {
      clearTimeout(requestTimeout);
    }
    if (!response.ok) {
      throw new Error(`DeepFace API returned ${response.status}`);
    }
    const payload = await response.json();
    if (subjectGeneration === deepFaceSubjectGeneration) {
      deepFaceEmotion = payload.status === 'ok' ? payload : null;
    }
  } catch (error) {
    // Hand and shoulder tracking remain available if the optional local
    // The local face-analysis service is not running or its dependencies are missing.
    if (!deepFaceWarningShown) {
      console.warn(
        'Face emotion API unavailable; face emotion will remain unavailable.',
        error,
      );
      deepFaceWarningShown = true;
    }
  } finally {
    deepFaceRequestInFlight = false;
  }
}

function deepFaceToJson(result) {
  if (!result || result.status !== 'ok') return null;
  const emotions = Object.fromEntries(
    Object.entries(result.emotions ?? {}).map(([label, score]) => [
      label.toLowerCase(),
      Number(score),
    ]),
  );
  return {
    source: result.source ?? 'face-model',
    confidence: Number(result.confidence ?? 0),
    label: result.dominant_emotion ?? 'not detected',
    landmarks: [],
    emotion_scores: emotions,
  };
}

function dispatchFrame(
  result,
  poseResult,
  faceResult,
  timestampMs,
  selectedSubject,
) {
  preparePointQualityFrame();
  const handednesses = result.handednesses ?? result.handedness ?? [];
  const allHands = (result.landmarks ?? []).map((landmarks, index) => {
    const category = handednesses[index]?.[0];
    const world = result.worldLandmarks?.[index] ?? [];
    const handedness = correctedHandedness(
      category?.categoryName,
      result.source,
    );
    const confidence = category?.score ?? 0;
    return {
      handedness,
      confidence,
      landmarks: Array.from({length: 21}, (_, landmarkIndex) => {
        const landmark = landmarks[landmarkIndex];
        const valid = validHandPoint(landmark);
        return {
          // Keep the fixed 21-point schema, but make an absent point explicit
          // with zero confidence instead of dereferencing null and killing the
          // continuous capture loop.
          x: valid ? landmark.x : 0,
          y: valid ? landmark.y : 0,
          z: valid ? landmark.z ?? 0 : 0,
          world_x: valid ? world[landmarkIndex]?.x : undefined,
          world_y: valid ? world[landmarkIndex]?.y : undefined,
          world_z: valid ? world[landmarkIndex]?.z : undefined,
          visibility: valid ? pointConfidence(landmark, confidence) : 0,
        };
      }),
    };
  });
  const subject = selectedSubject === undefined
    ? selectSubjectPose(poseResult)
    : selectedSubject;
  // Filter by the locked subject before updating finger histories. A second
  // person's hand must not contaminate the signer's per-finger smoothing.
  const hands = allHands
    .filter((hand) => handBelongsToSubject(hand, subject))
    .map((hand) => ({
      ...hand,
      finger_status: fingerStatusesForHand(
        hand.landmarks,
        hand.confidence,
        hand.handedness,
      ),
    }));
  const leftHand = hands.find((hand) => hand.handedness === 'left');
  const rightHand = hands.find((hand) => hand.handedness === 'right');
  const pose = subject?.visible === false ? [] : subject?.landmarks ?? [];
  const poseLandmarks = curatedLandmarks(
    pose,
    POSE_LANDMARKS,
    posePointToJson,
  );
  const leftShoulder = posePointToJson(pose[11], 11, 'left_shoulder');
  const rightShoulder = posePointToJson(pose[12], 12, 'right_shoulder');
  const faceLandmarks = selectSubjectFace(faceResult, subject);
  const faceUpper = curatedLandmarks(
    faceLandmarks,
    FACE_UPPER_LANDMARKS,
    facePointToJson,
  );
  const faceMouth = curatedLandmarks(
    faceLandmarks,
    FACE_MOUTH_LANDMARKS,
    facePointToJson,
  );
  if (subject?.visible !== true) {
    deepFaceSubjectGeneration += 1;
    deepFaceEmotion = null;
  }
  const face = deepFaceToJson(deepFaceEmotion);
  const subjectTracking = subject
    ? {
        locked: subject.locked === true,
        visible: subject.visible !== false,
        center_x: subject.visible === false ? null : subject.centerX,
        center_y: subject.visible === false ? null : subject.centerY,
        area: subject.visible === false ? 0 : subject.area,
        missing_frames: subject.missingFrames,
      }
    : {
        locked: false,
        center_x: null,
        center_y: null,
        area: 0,
        missing_frames: 0,
      };
  const landmarkWorlds = {
    // `hands` already carries the complete hand payload. Do not serialize it
    // again in `landmark_worlds`: duplicate JSON parsing on every video frame
    // was consuming time that the local model needs for tracking.
    pose: {
      landmarks: poseLandmarks,
    },
    face: {
      upper: faceUpper,
      mouth: faceMouth,
      emotion: face,
    },
  };

  let confidenceTotal = 0;
  let expectedPointCount = 0;
  const addConfidenceGroup = (points, expectedCount) => {
    if (expectedCount <= 0) return;
    confidenceTotal += points.reduce(
      (sum, point) => sum + clamp01(point.visibility),
      0,
    );
    expectedPointCount += expectedCount;
  };
  for (const hand of hands) {
    addConfidenceGroup(hand.landmarks, 21);
  }
  if (subject?.visible === true) {
    addConfidenceGroup(poseLandmarks, POSE_LANDMARKS.length);
  }
  if (faceResult?.faceLandmarks?.length > 0 && subject?.visible === true) {
    addConfidenceGroup(
      [...faceUpper, ...faceMouth],
      FACE_UPPER_LANDMARKS.length + FACE_MOUTH_LANDMARKS.length,
    );
  }
  const overallPointConfidence = expectedPointCount > 0
    ? clamp01(confidenceTotal / expectedPointCount)
    : 0;

  const frame = {
    timestamp_ms: timestampMs,
    // This score is the mean confidence of every point in the active worlds.
    // Missing points count as zero against that world's expected budget.
    processing_confidence: overallPointConfidence,
    point_confidence: overallPointConfidence,
    hands,
    face,
    left_shoulder: leftShoulder,
    right_shoulder: rightShoulder,
    landmark_worlds: landmarkWorlds,
    subject_tracking: subjectTracking,
  };
  // The Google ASL model needs the complete 543-point landmark tensor. Keep
  // that tensor inside this browser module only; the ordinary Flutter event
  // below remains the intentionally curated tracking contract.
  ingestAslFrame({
    timestampMs,
    faceLandmarks,
    poseLandmarks: pose,
    leftHand: leftHand?.landmarks ?? [],
    rightHand: rightHand?.landmarks ?? [],
    subjectTracking,
  });
  // Keep the local recognizer fed from every detector result, but cap the
  // expensive JS-to-Dart JSON handoff. Eighteen visual frames per second is
  // smooth in the overlay and frees time for MediaPipe and ONNX inference.
  if (timestampMs - lastFlutterFrameAt >= FLUTTER_EVENT_INTERVAL_MS) {
    lastFlutterFrameAt = timestampMs;
    window.dispatchEvent(
      new CustomEvent('signbridge-hand-frame', {
        detail: JSON.stringify(frame),
      }),
    );
  }
  void requestDeepFaceEmotion(subject, faceLandmarks);
}

function holisticResultAsTaskResults(results) {
  const landmarks = [];
  const handednesses = [];
  const addHand = (points, handedness) => {
    if (!Array.isArray(points) || points.length !== 21) return;
    landmarks.push(points);
    // Holistic is already person-relative and names its output slots exactly
    // as the Python Holistic API used by the model. The score is only used by
    // the visual-quality UI; model input stays the raw landmark coordinates.
    handednesses.push([{categoryName: handedness, score: 0.99}]);
  };
  addHand(results.leftHandLandmarks, 'left');
  addHand(results.rightHandLandmarks, 'right');
  return {
    source: 'holistic',
    landmarks,
    handednesses,
    worldLandmarks: [],
  };
}

function onHolisticResults(results) {
  if (!started) return;
  const now = performance.now();
  const pose = Array.isArray(results?.poseLandmarks)
    ? results.poseLandmarks
    : [];
  const face = Array.isArray(results?.faceLandmarks)
    ? results.faceLandmarks
    : [];
  dispatchFrame(
    holisticResultAsTaskResults(results ?? {}),
    {landmarks: pose.length === 33 ? [pose] : []},
    {faceLandmarks: face.length === 468 ? [face] : []},
    Date.now(),
  );
  trackingLoopFrameCount += 1;
  if (now - trackingLoopLastLogAt >= 10_000) {
    const elapsedSeconds = (now - trackingLoopStartedAt) / 1000;
    console.info(
      `SignBridge Holistic loop alive: ${trackingLoopFrameCount} frames over ${elapsedSeconds.toFixed(1)}s at ~${TRACKING_FPS} FPS.`,
    );
    trackingLoopLastLogAt = now;
  }
}

async function processHolisticFrame() {
  try {
    await holistic.send({image: video});
  } catch (error) {
    // A transient camera or WASM error must not end continuous capture.
    if (!trackingFrameErrorShown) {
      console.warn('A MediaPipe Holistic frame failed; continuing capture.', error);
      trackingFrameErrorShown = true;
    }
  } finally {
    detectionInProgress = false;
  }
}

function processFrame() {
  if (!started) return;
  try {
    syncVisibleCameraElement();
    if (video?.readyState >= 2 && holistic && !detectionInProgress) {
      const now = performance.now();
      if (now - lastProcessedAt >= DETECTION_INTERVAL_MS) {
        lastProcessedAt = now;
        detectionInProgress = true;
        void processHolisticFrame();
      }
    }
  } catch (error) {
    // A camera element can be replaced while Flutter rebuilds the page. Keep
    // the outer loop alive so the next video frame can reconnect to the view.
    if (!trackingFrameErrorShown) {
      console.warn('Tracking loop recovered from a camera error.', error);
      trackingFrameErrorShown = true;
    }
  } finally {
    if (started) animationFrame = requestAnimationFrame(processFrame);
  }
}

function createHolistic() {
  const Holistic = globalThis.Holistic;
  if (typeof Holistic !== 'function') {
    throw new Error('MediaPipe Holistic did not load. Refresh and try again.');
  }
  const tracker = new Holistic({
    locateFile: (file) => `${HOLISTIC_CDN_BASE}/${file}`,
  });
  // These match the upstream Python live-recognition defaults: one coherent
  // Holistic stream, 468 face landmarks (no iris refinement), full pose, and
  // left/right hand slots produced by the same graph as training data.
  tracker.setOptions({
    modelComplexity: 1,
    smoothLandmarks: true,
    enableSegmentation: false,
    smoothSegmentation: false,
    refineFaceLandmarks: false,
    minDetectionConfidence: 0.5,
    minTrackingConfidence: 0.5,
  });
  tracker.onResults(onHolisticResults);
  return tracker;
}

function waitForCameraElement(timeoutMs = 3000) {
  const startedAt = performance.now();
  return new Promise((resolve, reject) => {
    const findElement = () => {
      const element = visibleCameraElement();
      if (element) {
        resolve(element);
        return;
      }
      if (performance.now() - startedAt >= timeoutMs) {
        reject(new Error('SignBridge camera view was not mounted in time.'));
        return;
      }
      requestAnimationFrame(findElement);
    };
    findElement();
  });
}

async function start() {
  if (started) return;
  // A hot restart or an interrupted startup can leave an old stream or
  // detector alive. Release those resources before requesting the camera
  // again so the next page/start cycle always gets a clean session.
  await stop();
  try {
    // Flutter marks the camera as ready and mounts HtmlElementView on the next
    // frame. Wait for that element before requesting permission or attaching
    // the stream, otherwise the first click can fail even though permission
    // exists.
    video = await waitForCameraElement();

    stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        facingMode: 'user',
        // Match the upstream model's own Holistic live-recognition capture.
        width: { ideal: 640, max: 640 },
        height: { ideal: 480, max: 480 },
        frameRate: { ideal: 30, max: 30 },
      },
    });
    video.srcObject = stream;
    video.muted = true;
    video.playsInline = true;
    await video.play();

    holistic = createHolistic();
  } catch (error) {
    await stop();
    throw error;
  }

  started = true;
  trackingFrameErrorShown = false;
  lastProcessedAt = 0;
  lastFlutterFrameAt = 0;
  lastPointQualityAt = 0;
  detectionInProgress = false;
  trackingLoopFrameCount = 0;
  trackingLoopStartedAt = performance.now();
  trackingLoopLastLogAt = trackingLoopStartedAt;
  subjectTrack = null;
  subjectAcquire = null;
  subjectReferenceIdentity = null;
  fingerQualityHistory = {left: {}, right: {}, unknown: {}};
  void prepareAslRecognizer().catch(() => {
    // A missing locally-exported model must not stop ordinary landmark
    // tracking. Flutter will surface the model-unavailable result at the end
    // of a captured sign instead.
  });
  processFrame();
}

async function stop() {
  started = false;
  if (animationFrame) cancelAnimationFrame(animationFrame);
  stream?.getTracks().forEach((track) => track.stop());
  stream = null;
  if (video) video.srcObject = null;
  deepFaceEmotion = null;
  deepFaceRequestInFlight = false;
  lastDeepFaceRequestAt = 0;
  deepFaceSubjectGeneration += 1;
  await holistic?.close();
  holistic = null;
  lastProcessedAt = 0;
  lastFlutterFrameAt = 0;
  lastPointQualityAt = 0;
  detectionInProgress = false;
  trackingLoopFrameCount = 0;
  trackingLoopStartedAt = 0;
  trackingLoopLastLogAt = 0;
  subjectTrack = null;
  subjectAcquire = null;
  subjectReferenceIdentity = null;
  fingerQualityHistory = {left: {}, right: {}, unknown: {}};
  resetAslCapture();
}

globalThis.addEventListener('pagehide', () => {
  void stop();
});

window.signBridgeHandTracker = {
  start,
  stop,
  beginAslCapture,
  finishAslCapture,
};
