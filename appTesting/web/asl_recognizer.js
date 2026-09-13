// Browser-local inference adapter for the James Bustos 250-sign TensorFlow Lite model.
//
// The tracker calls `ingestAslFrame()` with MediaPipe's complete landmark
// arrays for every valid Holistic frame. A bounded single-sign window remains
// in this page: only the final sign and its confidence are returned to Dart.
//
// The model and pinned TensorFlow Lite WASM runtime are served by this app.
// Camera images and landmark sequences stay in this browser.
import {createAslModelHandle} from './asl_tflite_runtime.js';

const MODEL_URL = new URL(
  './models/jamesbustos_asl_250_809d456.tflite',
  import.meta.url,
).toString();
const MANIFEST_URL = new URL(
  './models/jamesbustos_asl_250_809d456.manifest.json', import.meta.url,
).toString();

// The upstream TFLite input is [frames, 543, 3], without a batch axis.
// Its initial allocation is fixed to 30 frames for the browser runtime.
// Kaggle/Holistic order: face, LEFT HAND, pose, right hand. Missing = NaN.
const TARGET_FRAMES = 30;
const FACE_POINTS = 468;
const POSE_POINTS = 33;
const HAND_POINTS = 21;
const VALUES_PER_POINT = 3;
const MODEL_LANDMARKS_PER_FRAME =
  FACE_POINTS + POSE_POINTS + HAND_POINTS * 2;
const VALUES_PER_FRAME = MODEL_LANDMARKS_PER_FRAME * VALUES_PER_POINT;
// Require a real one-second window, matching the upstream live demo.
const MIN_MODEL_CAPTURED_FRAMES = TARGET_FRAMES;
const MIN_TEMPLATE_CAPTURED_FRAMES = 5;
const MAX_CAPTURED_FRAMES = 180;
const MAX_CAPTURE_DURATION_MS = 6000;
const MAX_FRAME_GAP_MS = 350;
const PRE_ROLL_FRAMES = 3;
const ACTIVE_MOTION_THRESHOLD = 0.003;
const ACTIVE_LEADING_CONTEXT_FRAMES = 2;
const ACTIVE_TRAILING_CONTEXT_FRAMES = 4;
const MIN_CONFIDENCE = 0.7;
const MODEL_VERSION = 'jamesbustos_asl_250_809d456';

// Exact Gather indices inspected in the shipped TFLite graph: 13 face
// landmarks and all 75 hand/pose points. Preprocessing is inside the model.
const MODEL_FACE_FEATURE_POINTS = [
  0, 9, 11, 13, 14, 17, 117, 118, 119, 199, 346, 347, 348,
];
const MODEL_FEATURE_POINTS_PER_FRAME =
  MODEL_FACE_FEATURE_POINTS.length + POSE_POINTS + HAND_POINTS * 2;
const TEMPLATE_FEATURE_POINTS = MODEL_FACE_FEATURE_POINTS.length + HAND_POINTS * 2;
const LEFT_HAND_START = FACE_POINTS;
const POSE_START = LEFT_HAND_START + HAND_POINTS;
const RIGHT_HAND_START = POSE_START + POSE_POINTS;

// Exact upstream prediction indices; notably class 0 is uppercase "TV".
const LABELS = [
  "TV", "after", "airplane", "all", "alligator", "animal", "another", "any",
  "apple", "arm", "aunt", "awake", "backyard", "bad", "balloon", "bath",
  "because", "bed", "bedroom", "bee", "before", "beside", "better", "bird",
  "black", "blow", "blue", "boat", "book", "boy", "brother", "brown",
  "bug", "bye", "callonphone", "can", "car", "carrot", "cat", "cereal",
  "chair", "cheek", "child", "chin", "chocolate", "clean", "close", "closet",
  "cloud", "clown", "cow", "cowboy", "cry", "cut", "cute", "dad",
  "dance", "dirty", "dog", "doll", "donkey", "down", "drawer", "drink",
  "drop", "dry", "dryer", "duck", "ear", "elephant", "empty", "every",
  "eye", "face", "fall", "farm", "fast", "feet", "find", "fine",
  "finger", "finish", "fireman", "first", "fish", "flag", "flower", "food",
  "for", "frenchfries", "frog", "garbage", "gift", "giraffe", "girl", "give",
  "glasswindow", "go", "goose", "grandma", "grandpa", "grass", "green", "gum",
  "hair", "happy", "hat", "hate", "have", "haveto", "head", "hear",
  "helicopter", "hello", "hen", "hesheit", "hide", "high", "home", "horse",
  "hot", "hungry", "icecream", "if", "into", "jacket", "jeans", "jump",
  "kiss", "kitty", "lamp", "later", "like", "lion", "lips", "listen",
  "look", "loud", "mad", "make", "man", "many", "milk", "minemy",
  "mitten", "mom", "moon", "morning", "mouse", "mouth", "nap", "napkin",
  "night", "no", "noisy", "nose", "not", "now", "nuts", "old",
  "on", "open", "orange", "outside", "owie", "owl", "pajamas", "pen",
  "pencil", "penny", "person", "pig", "pizza", "please", "police", "pool",
  "potty", "pretend", "pretty", "puppy", "puzzle", "quiet", "radio", "rain",
  "read", "red", "refrigerator", "ride", "room", "sad", "same", "say",
  "scissors", "see", "shhh", "shirt", "shoe", "shower", "sick", "sleep",
  "sleepy", "smile", "snack", "snow", "stairs", "stay", "sticky", "store",
  "story", "stuck", "sun", "table", "talk", "taste", "thankyou", "that",
  "there", "think", "thirsty", "tiger", "time", "tomorrow", "tongue", "tooth",
  "toothbrush", "touch", "toy", "tree", "uncle", "underwear", "up", "vacuum",
  "wait", "wake", "water", "wet", "weus", "where", "white", "who",
  "why", "will", "wolf", "yellow", "yes", "yesterday", "yourself", "yucky",
  "zebra", "zipper",
];

// A correction is intentionally keyed to a local motion template, not to a
// model label. For example, a person can teach their own `bye` motion after a
// mistaken `blue` result without making every genuine blue sign say `bye`.
// Templates contain normalized landmark coordinates only and never leave this
// browser unless the user independently chooses to submit a final word.
// A new model-specific key prevents old 25-word corrections from overriding
// predictions from the replacement. Existing stored data is left untouched.
const PERSONAL_TEMPLATE_STORAGE_KEY = 'signbridge.asl.jamesbustos-250.templates.v1';
const PERSONAL_TEMPLATE_SAMPLES_PER_WORD = 5;
const PERSONAL_TEMPLATE_DEFAULT_MAX_DISTANCE = 0.6;
const PERSONAL_TEMPLATE_MIN_MAX_DISTANCE = 0.4;
const PERSONAL_TEMPLATE_MAX_MAX_DISTANCE = 0.85;
const PERSONAL_TEMPLATE_AMBIGUITY_MARGIN = 0.08;
const PERSONAL_TEMPLATE_SIGNATURE_LENGTH =
  TARGET_FRAMES * TEMPLATE_FEATURE_POINTS * 3;

let sessionPromise;
let captureActive = false;
let rollingFrames = [];
let captureFrames = [];
let captureGeneration = 0;
let captureOverflowed = false;
let lastCapturedAtMs = Number.NEGATIVE_INFINITY;
let lastCompletedSignature;
let status = 'idle';
let lastError;

function dispatchStatus(nextStatus, detail = '') {
  status = nextStatus;
  window.dispatchEvent(
    new CustomEvent('signbridge-asl-status', {
      detail: JSON.stringify({status, detail, model_version: MODEL_VERSION}),
    }),
  );
}

function finiteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

function validPoint(point) {
  return point && finiteNumber(point.x) && finiteNumber(point.y) &&
    finiteNumber(point.z);
}

function pointZ(point) {
  return finiteNumber(point?.z) ? point.z : 0;
}

function copyPoints(target, startPoint, points, pointCount) {
  for (let index = 0; index < pointCount; index += 1) {
    const point = points?.[index];
    if (!validPoint(point)) continue;
    const offset = (startPoint + index) * VALUES_PER_POINT;
    target[offset] = point.x;
    target[offset + 1] = point.y;
    target[offset + 2] = pointZ(point);
  }
}

function hasRequiredModelFaceFeatures(faceLandmarks) {
  return (
    Array.isArray(faceLandmarks) &&
    faceLandmarks.length >= FACE_POINTS &&
    MODEL_FACE_FEATURE_POINTS.every((index) => validPoint(faceLandmarks[index]))
  );
}

function hasModelCompatibleFrame({faceLandmarks, poseLandmarks}) {
  return (
    hasRequiredModelFaceFeatures(faceLandmarks) &&
    Array.isArray(poseLandmarks) &&
    poseLandmarks.length >= POSE_POINTS
  );
}

function validHand(points) {
  return Array.isArray(points) && points.length === HAND_POINTS &&
    points.every((point) => validPoint(point) && point.visibility !== 0);
}

export function packFrame({faceLandmarks, poseLandmarks, leftHand, rightHand}) {
  const values = new Float32Array(VALUES_PER_FRAME).fill(Number.NaN);
  copyPoints(values, 0, faceLandmarks, FACE_POINTS);
  copyPoints(values, POSE_START, poseLandmarks, POSE_POINTS);
  copyPoints(values, LEFT_HAND_START, leftHand, HAND_POINTS);
  copyPoints(
    values,
    RIGHT_HAND_START,
    rightHand,
    HAND_POINTS,
  );
  return values;
}

export function resampleFrames(frames) {
  const output = new Float32Array(TARGET_FRAMES * VALUES_PER_FRAME);
  const lastIndex = frames.length - 1;
  for (let targetIndex = 0; targetIndex < TARGET_FRAMES; targetIndex += 1) {
    // Preserve the whole sign when it is longer than the 30-frame live window.
    // Sampling is an application policy; the upstream demo uses a rolling window.
    const sourceIndex = Math.floor(
      (targetIndex * lastIndex) / Math.max(1, TARGET_FRAMES - 1),
    );
    output.set(frames[sourceIndex].values, targetIndex * VALUES_PER_FRAME);
  }
  return output;
}

function hasTrackedHandPoint(values, offset) {
  const x = values[offset];
  const y = values[offset + 1];
  const z = values[offset + 2];
  return finiteNumber(x) && finiteNumber(y) && finiteNumber(z);
}

function averageHandMotion(previous, current) {
  const handOffsets = [
    (LEFT_HAND_START) * VALUES_PER_POINT,
    (RIGHT_HAND_START) * VALUES_PER_POINT,
  ];
  let total = 0;
  let count = 0;
  for (const handOffset of handOffsets) {
    for (let index = 0; index < HAND_POINTS; index += 1) {
      const offset = handOffset + index * VALUES_PER_POINT;
      if (
        !hasTrackedHandPoint(previous.values, offset) ||
        !hasTrackedHandPoint(current.values, offset)
      ) {
        continue;
      }
      const dx = current.values[offset] - previous.values[offset];
      const dy = current.values[offset + 1] - previous.values[offset + 1];
      total += Math.hypot(dx, dy);
      count += 1;
    }
  }
  return count === 0 ? 0 : total / count;
}

function activeMotionFrames(frames) {
  if (frames.length < 3) return frames;
  let firstActive = -1;
  let lastActive = -1;
  for (let index = 1; index < frames.length; index += 1) {
    if (
      averageHandMotion(frames[index - 1], frames[index]) >=
      ACTIVE_MOTION_THRESHOLD
    ) {
      firstActive = firstActive === -1 ? index : firstActive;
      lastActive = index;
    }
  }
  if (firstActive === -1 || lastActive === -1) return frames;

  let start = Math.max(0, firstActive - ACTIVE_LEADING_CONTEXT_FRAMES);
  let end = Math.min(
    frames.length,
    lastActive + ACTIVE_TRAILING_CONTEXT_FRAMES + 1,
  );
  // Preserve actual temporal samples for the browser input allocation. Extend the
  // selected interval with real context instead of repeating short captures.
  if (end - start < TARGET_FRAMES) {
    start = Math.max(0, end - TARGET_FRAMES);
    end = Math.min(frames.length, Math.max(end, start + TARGET_FRAMES));
  }
  const activeFrames = frames.slice(start, end);
  return activeFrames.length >= MIN_TEMPLATE_CAPTURED_FRAMES
    ? activeFrames
    : frames;
}

function handTrackedInFrame(frame, handStartPoint) {
  const handStartOffset = handStartPoint * VALUES_PER_POINT;
  for (let index = 0; index < HAND_POINTS; index += 1) {
    if (
      hasTrackedHandPoint(
        frame.values,
        handStartOffset + index * VALUES_PER_POINT,
      )
    ) {
      return true;
    }
  }
  return false;
}

// This is deliberately an audit of the model input shape and availability,
// not a copy of its coordinates. It makes the browser-side handoff observable
// without exposing camera images or landmark data to Flutter or the backend.
function modelInputSummary(frames, capturedFrameCount) {
  const leftHandStart = LEFT_HAND_START;
  const rightHandStart = RIGHT_HAND_START;
  const leftHandTrackedFrames = frames.filter((frame) =>
    handTrackedInFrame(frame, leftHandStart),
  ).length;
  const rightHandTrackedFrames = frames.filter((frame) =>
    handTrackedInFrame(frame, rightHandStart),
  ).length;
  return {
    source: 'mediapipe_holistic',
    landmark_points: MODEL_LANDMARKS_PER_FRAME,
    coordinate_axes: VALUES_PER_POINT,
    model_frames: TARGET_FRAMES,
    model_feature_points: MODEL_FEATURE_POINTS_PER_FRAME,
    model_face_feature_points: MODEL_FACE_FEATURE_POINTS.length,
    model_hand_feature_points: HAND_POINTS * 2,
    model_pose_feature_points: POSE_POINTS,
    captured_frames: capturedFrameCount,
    selected_frames: frames.length,
    face_points: FACE_POINTS,
    pose_points: POSE_POINTS,
    left_hand_points: HAND_POINTS,
    right_hand_points: HAND_POINTS,
    left_hand_tracked_frames: leftHandTrackedFrames,
    right_hand_tracked_frames: rightHandTrackedFrames,
  };
}

function modelInputDetail(summary) {
  return (
    `Model input: ${summary.landmark_points} x/y/z landmarks × ` +
    `${summary.model_frames} frames · features ${summary.model_face_feature_points} ` +
    `face + ${summary.model_hand_feature_points} hand + ${summary.model_pose_feature_points} pose · hands L ${summary.left_hand_tracked_frames}/` +
    `${summary.selected_frames} R ${summary.right_hand_tracked_frames}/` +
    `${summary.selected_frames}`
  );
}

function normalizedPersonalLabel(value) {
  const label = String(value ?? '').trim().toLowerCase();
  return LABELS.find((candidate) => candidate.toLowerCase() === label) ?? null;
}

function pointOffset(frameOffset, pointIndex) {
  return frameOffset + pointIndex * VALUES_PER_POINT;
}

export function completedCaptureSignature(frames) {
  if (!Array.isArray(frames) || frames.length < MIN_TEMPLATE_CAPTURED_FRAMES) {
    return null;
  }
  const values = resampleFrames(frames);
  const featureFrames = [];
  let faceAnchorX = 0;
  let faceAnchorY = 0;

  for (let frameIndex = 0; frameIndex < TARGET_FRAMES; frameIndex += 1) {
    const frameOffset = frameIndex * VALUES_PER_FRAME;
    const anchorOffset = pointOffset(frameOffset, 17);
    faceAnchorX += values[anchorOffset];
    faceAnchorY += values[anchorOffset + 1];
    const features = [];
    const appendFeature = (pointIndex) => {
      const offset = pointOffset(frameOffset, pointIndex);
      features.push({
        x: finiteNumber(values[offset]) ? values[offset] : 0,
        y: finiteNumber(values[offset + 1]) ? values[offset + 1] : 0,
        present: hasTrackedHandPoint(values, offset),
      });
    };
    for (const pointIndex of MODEL_FACE_FEATURE_POINTS) {
      appendFeature(pointIndex);
    }
    for (let pointIndex = 0; pointIndex < HAND_POINTS; pointIndex += 1) {
      appendFeature(LEFT_HAND_START + pointIndex);
    }
    for (let pointIndex = 0; pointIndex < HAND_POINTS; pointIndex += 1) {
      appendFeature(
        RIGHT_HAND_START + pointIndex,
      );
    }
    featureFrames.push(features);
  }

  // This normalization belongs only to optional personal gesture matching.
  // TFLite receives raw x/y/z with NaN; it performs its own preprocessing.
  faceAnchorX /= TARGET_FRAMES;
  faceAnchorY /= TARGET_FRAMES;
  const featureCount = TARGET_FRAMES * TEMPLATE_FEATURE_POINTS;
  const featureMeanX = featureFrames.flat().reduce((sum, p) => sum + p.x, 0) / featureCount;
  const featureMeanY = featureFrames.flat().reduce((sum, p) => sum + p.y, 0) / featureCount;
  let xSquaredDistance = 0;
  let ySquaredDistance = 0;
  for (const features of featureFrames) {
    for (const feature of features) {
      xSquaredDistance += (feature.x - featureMeanX) ** 2;
      ySquaredDistance += (feature.y - featureMeanY) ** 2;
    }
  }
  const varianceDivisor = Math.max(1, featureCount - 1);
  const xScale = Math.sqrt(xSquaredDistance / varianceDivisor) + 1e-8;
  const yScale = Math.sqrt(ySquaredDistance / varianceDivisor) + 1e-8;
  const signature = [];
  for (const features of featureFrames) {
    for (const feature of features) {
      signature.push(
        (feature.x - faceAnchorX) / xScale,
        (feature.y - faceAnchorY) / yScale,
        feature.present ? 1 : 0,
      );
    }
  }
  return signature.length === PERSONAL_TEMPLATE_SIGNATURE_LENGTH
    ? signature
    : null;
}

function storedPersonalTemplate(value) {
  const label = normalizedPersonalLabel(value?.label);
  const signature = value?.signature;
  if (
    !label ||
    !Array.isArray(signature) ||
    signature.length !== PERSONAL_TEMPLATE_SIGNATURE_LENGTH ||
    !signature.every(finiteNumber)
  ) {
    return null;
  }
  return {
    label,
    signature,
    createdAt: Number(value.createdAt) || 0,
  };
}

function loadPersonalTemplates() {
  try {
    const stored = globalThis.localStorage?.getItem(PERSONAL_TEMPLATE_STORAGE_KEY);
    if (!stored) return [];
    const decoded = JSON.parse(stored);
    if (!Array.isArray(decoded)) return [];
    return decoded.map(storedPersonalTemplate).filter((template) => template);
  } catch (_) {
    return [];
  }
}

function savePersonalTemplates(templates) {
  try {
    globalThis.localStorage?.setItem(
      PERSONAL_TEMPLATE_STORAGE_KEY,
      JSON.stringify(templates),
    );
    return true;
  } catch (_) {
    return false;
  }
}

function personalTemplateDistance(first, second) {
  if (
    !Array.isArray(first) ||
    !Array.isArray(second) ||
    first.length !== PERSONAL_TEMPLATE_SIGNATURE_LENGTH ||
    second.length !== PERSONAL_TEMPLATE_SIGNATURE_LENGTH
  ) {
    return Number.POSITIVE_INFINITY;
  }
  let squaredDistance = 0;
  let componentCount = 0;
  for (let index = 0; index < first.length; index += 3) {
    const firstPresent = first[index + 2] > 0.5;
    const secondPresent = second[index + 2] > 0.5;
    if (firstPresent !== secondPresent) {
      squaredDistance += 0.81;
      componentCount += 1;
      continue;
    }
    if (!firstPresent) continue;
    const dx = first[index] - second[index];
    const dy = first[index + 1] - second[index + 1];
    squaredDistance += dx * dx + dy * dy;
    componentCount += 2;
  }
  return componentCount > 0
    ? Math.sqrt(squaredDistance / componentCount)
    : Number.POSITIVE_INFINITY;
}

function median(values) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((first, second) => first - second);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}

function personalTemplateThreshold(label, templates) {
  const sameLabel = templates.filter((template) => template.label === label);
  if (sameLabel.length < 2) return PERSONAL_TEMPLATE_DEFAULT_MAX_DISTANCE;
  const neighborDistances = sameLabel.map((template, index) => {
    const alternatives = sameLabel
      .filter((_, otherIndex) => otherIndex !== index)
      .map((other) =>
        personalTemplateDistance(template.signature, other.signature),
      );
    return Math.min(...alternatives);
  });
  return Math.min(
    PERSONAL_TEMPLATE_MAX_MAX_DISTANCE,
    Math.max(
      PERSONAL_TEMPLATE_MIN_MAX_DISTANCE,
      median(neighborDistances) * 1.65,
    ),
  );
}

function personalTemplateMatch(signature) {
  if (!signature) return null;
  const templates = loadPersonalTemplates();
  const byLabel = new Map();
  for (const template of templates) {
    const distance = personalTemplateDistance(signature, template.signature);
    const previous = byLabel.get(template.label);
    if (!previous || distance < previous.distance) {
      byLabel.set(template.label, {label: template.label, distance});
    }
  }
  const candidates = [...byLabel.values()].sort(
    (first, second) => first.distance - second.distance,
  );
  const best = candidates[0];
  const runnerUp = candidates[1];
  if (!best) return null;
  const threshold = personalTemplateThreshold(best.label, templates);
  if (best.distance > threshold) return null;
  if (
    runnerUp &&
    runnerUp.distance - best.distance < PERSONAL_TEMPLATE_AMBIGUITY_MARGIN
  ) {
    return null;
  }
  const confidence = Math.max(
    0.8,
    Math.min(0.99, 1 - best.distance / (threshold * 5)),
  );
  return {
    ...best,
    confidence: Number(confidence.toFixed(6)),
    threshold: Number(threshold.toFixed(6)),
  };
}

export function teachLastAslCapture(label) {
  const normalizedLabel = normalizedPersonalLabel(label);
  if (!normalizedLabel) {
    return {status: 'invalid_label', sample_count: 0};
  }
  if (!lastCompletedSignature) {
    return {status: 'no_capture', sample_count: 0};
  }
  const templates = loadPersonalTemplates();
  const retained = templates
    .filter((template) => template.label !== normalizedLabel)
    .concat(
      templates
        .filter((template) => template.label === normalizedLabel)
        .sort((first, second) => first.createdAt - second.createdAt)
        .slice(-(PERSONAL_TEMPLATE_SAMPLES_PER_WORD - 1)),
    );
  retained.push({
    label: normalizedLabel,
    signature: lastCompletedSignature,
    createdAt: Date.now(),
  });
  if (!savePersonalTemplates(retained)) {
    return {status: 'storage_unavailable', sample_count: 0};
  }
  return {
    status: 'stored',
    label: normalizedLabel,
    sample_count: retained.filter((template) => template.label === normalizedLabel)
      .length,
  };
}

export function rankedPredictions(scores) {
  if (!scores || scores.length !== LABELS.length ||
      !Array.from(scores).every((value) => finiteNumber(value) && value >= 0 && value <= 1)) {
    throw new Error('ASL model must return 250 finite probabilities in manifest label order.');
  }
  const probabilities = Array.from(scores);
  const total = probabilities.reduce((sum, value) => sum + value, 0);
  if (Math.abs(total - 1) > 0.001) {
    throw new Error('ASL model probabilities must sum to one.');
  }
  // The TFLite graph already ends in softmax. Applying it again destroys confidence.
  return probabilities
    .map((confidence, index) => ({
      word: LABELS[index] ?? `class_${index}`,
      confidence,
    }))
    .sort((first, second) => second.confidence - first.confidence)
    .slice(0, 3)
    .map((candidate, index) => ({
      ...candidate,
      rank: index + 1,
      confidence: Number(candidate.confidence.toFixed(6)),
    }));
}

export function validateModelManifest(manifest) {
  if (manifest?.model_id !== MODEL_VERSION ||
      manifest.input_name !== 'serving_default_inputs:0' ||
      manifest.output_name !== 'StatefulPartitionedCall:0' ||
      manifest.output_type !== 'probabilities' || manifest.missing_landmarks !== 'NaN' ||
      JSON.stringify(manifest.output_shape) !== JSON.stringify([1, LABELS.length]) ||
      JSON.stringify(manifest.input_shape) !== JSON.stringify([TARGET_FRAMES, MODEL_LANDMARKS_PER_FRAME, 3]) ||
      JSON.stringify(manifest.landmark_order) !== JSON.stringify(['face_468', 'left_hand_21', 'pose_33', 'right_hand_21']) ||
      JSON.stringify(manifest.labels) !== JSON.stringify(LABELS)) {
    throw new Error('ASL model manifest does not match the tracker tensor and label order.');
  }
}

function unknownOutcome(reason, frames = [], metadata = {}) {
  return {
    status: 'unknown',
    reason,
    word: null,
    confidence: 0,
    alternatives: [],
    model_version: MODEL_VERSION,
    frame_count: frames.length,
    started_at_ms: frames[0]?.timestampMs ?? null,
    ended_at_ms: frames.at(-1)?.timestampMs ?? null,
    ...metadata,
  };
}

async function createSession() {
  dispatchStatus('loading', 'Preparing local 250-sign ASL model');
  const manifestResponse = await fetch(MANIFEST_URL);
  if (!manifestResponse.ok) throw new Error('ASL model manifest could not be loaded.');
  const manifest = await manifestResponse.json();
  validateModelManifest(manifest);
  const handle = await createAslModelHandle(MODEL_URL, manifest);
  try {
    const warmup = new Float32Array(TARGET_FRAMES * VALUES_PER_FRAME).fill(Number.NaN);
    // The first invocation reallocates dynamic LSTM tensors. TFJS-TFLite can
    // return a stale output view on that call; prime it before validating.
    await handle.predict(warmup);
    rankedPredictions(await handle.predict(warmup));
  } catch (error) {
    handle.dispose();
    throw error;
  }
  lastError = undefined;
  dispatchStatus('ready', '250-sign ASL model ready');
  return handle;
}

export function prepareAslRecognizer() {
  if (!sessionPromise) {
    sessionPromise = createSession().catch((error) => {
      sessionPromise = undefined;
      lastError = error;
      dispatchStatus('unavailable', String(error?.message ?? error));
      throw error;
    });
  }
  return sessionPromise;
}

export function beginAslCapture() {
  if (captureActive) return;
  captureActive = true;
  captureGeneration += 1;
  captureFrames = rollingFrames.slice(-PRE_ROLL_FRAMES);
  captureOverflowed = false;
  // Begin loading as early as possible so an ordinary one-second sign does
  // not have to wait for the model download after the signer has finished.
  void prepareAslRecognizer().catch(() => {});
}

export function resetAslCapture() {
  captureGeneration += 1;
  captureActive = false;
  rollingFrames = [];
  captureFrames = [];
  captureOverflowed = false;
  lastCompletedSignature = undefined;
  lastCapturedAtMs = Number.NEGATIVE_INFINITY;
}

export function ingestAslFrame({
  timestampMs,
  faceLandmarks,
  poseLandmarks,
  leftHand,
  rightHand,
  subjectTracking,
}) {
  if (subjectTracking?.locked !== true) {
    rollingFrames = [];
    return;
  }
  if (
    subjectTracking.visible === false ||
    !hasModelCompatibleFrame({
      faceLandmarks,
      poseLandmarks,
      leftHand,
      rightHand,
    })
  ) {
    return;
  }
  const recordedAtMs = finiteNumber(timestampMs) ? timestampMs : Date.now();
  if (recordedAtMs <= lastCapturedAtMs) return;
  if (recordedAtMs - lastCapturedAtMs > MAX_FRAME_GAP_MS) rollingFrames = [];
  lastCapturedAtMs = recordedAtMs;
  const frame = {
    timestampMs: recordedAtMs,
    values: packFrame({
      faceLandmarks, poseLandmarks,
      leftHand: validHand(leftHand) ? leftHand : [],
      rightHand: validHand(rightHand) ? rightHand : [],
    }),
  };
  rollingFrames.push(frame);
  if (rollingFrames.length > PRE_ROLL_FRAMES) rollingFrames.shift();
  if (captureActive) {
    captureFrames.push(frame);
    if (captureFrames.length > MAX_CAPTURED_FRAMES) {
      captureOverflowed = true;
      captureFrames.shift();
    }
  }
}

export async function finishAslCapture() {
  if (!captureActive) return unknownOutcome('no_active_capture');
  const generation = captureGeneration;
  captureActive = false;
  const captured = captureFrames;
  captureFrames = [];
  rollingFrames = [];
  lastCompletedSignature = undefined;
  // A pause completes the sign; it must not push the sign itself out of a
  // rolling one-second window. Keep the whole bounded capture, then trim
  // idle context before selecting the model's 30 temporal samples.
  const frames = activeMotionFrames(captured);
  // Personal corrections retain their own movement-focused signature so a
  // previously taught sign remains stable across naturally longer pauses.
  const templateFrames = activeMotionFrames(captured);
  const inputSummary = modelInputSummary(frames, captured.length);
  const inputDetail = modelInputDetail(inputSummary);
  if (captured.some((frame, index) => index > 0 &&
      frame.timestampMs - captured[index - 1].timestampMs > MAX_FRAME_GAP_MS)) {
    return unknownOutcome('tracking_interrupted', frames, {input_summary: inputSummary});
  }
  if (captureOverflowed || captured.length >= MAX_CAPTURED_FRAMES ||
      captured.at(-1)?.timestampMs - captured[0]?.timestampMs > MAX_CAPTURE_DURATION_MS) {
    return unknownOutcome('capture_too_long', frames, {input_summary: inputSummary});
  }
  const handFrames = frames.filter((frame) =>
    handTrackedInFrame(frame, LEFT_HAND_START) ||
    handTrackedInFrame(frame, RIGHT_HAND_START));
  if (handFrames.length < MIN_MODEL_CAPTURED_FRAMES) {
    return unknownOutcome('too_few_hand_frames', frames, {
      input_summary: inputSummary, detail: inputDetail,
    });
  }
  if (frames.length < MIN_MODEL_CAPTURED_FRAMES) {
    return unknownOutcome('too_few_model_frames', frames, {
      captured_frame_count: captured.length,
      input_summary: inputSummary,
      detail: inputDetail,
    });
  }

  // Retain a compact, normalized signature only for the completed motion.
  // It lets the signer correct this exact result after the generic model has
  // made a mistake. The signature is kept in this browser only if they tap
  // the explicit "Teach it" action below in Flutter.
  lastCompletedSignature = completedCaptureSignature(templateFrames);
  const personalMatch = personalTemplateMatch(lastCompletedSignature);
  if (personalMatch) {
    return {
      status: 'recognized',
      word: personalMatch.label,
      confidence: personalMatch.confidence,
      alternatives: [
        {
          word: personalMatch.label,
          confidence: personalMatch.confidence,
          rank: 1,
        },
      ],
      model_version: `${MODEL_VERSION}+personal-template`,
      frame_count: frames.length,
      captured_frame_count: captured.length,
      started_at_ms: frames[0]?.timestampMs ?? null,
      ended_at_ms: frames.at(-1)?.timestampMs ?? null,
      input_summary: inputSummary,
      detail:
        `Personal gesture template · distance ${personalMatch.distance.toFixed(3)}/` +
        `${personalMatch.threshold.toFixed(3)} · ` +
        inputDetail,
      execution_provider: 'personal_template',
    };
  }

  let handle;
  try {
    handle = await prepareAslRecognizer();
    if (generation !== captureGeneration) return unknownOutcome('capture_cancelled');
  } catch (_) {
    return {
      status: 'unavailable',
      reason: 'model_unavailable',
      detail: String(lastError?.message ?? lastError ?? 'Model unavailable'),
      word: null,
      confidence: 0,
      alternatives: [],
      model_version: MODEL_VERSION,
      frame_count: frames.length,
      captured_frame_count: captured.length,
      input_summary: inputSummary,
      started_at_ms: frames[0]?.timestampMs ?? null,
      ended_at_ms: frames.at(-1)?.timestampMs ?? null,
    };
  }

  try {
    const startedAt = performance.now();
    const scores = await handle.predict(resampleFrames(frames));
    if (generation !== captureGeneration) return unknownOutcome('capture_cancelled');
    const alternatives = rankedPredictions(scores);
    const best = alternatives[0];
    const inferenceMs = Math.round(performance.now() - startedAt);
    // The upstream application accepts its top class when it exceeds 70%.
    // Do not add a second margin gate: a calibrated softmax can be confident
    // even when the runner-up is nearby.
    if (!best || best.confidence < MIN_CONFIDENCE) {
      return {
        ...unknownOutcome('low_confidence', frames),
        confidence: best?.confidence ?? 0,
        alternatives,
        inference_ms: inferenceMs,
        execution_provider: handle.provider,
        captured_frame_count: captured.length,
        input_summary: inputSummary,
        detail: inputDetail,
      };
    }
    return {
      status: 'recognized',
      word: best.word,
      confidence: best.confidence,
      alternatives,
      model_version: MODEL_VERSION,
      frame_count: frames.length,
      captured_frame_count: captured.length,
      input_summary: inputSummary,
      started_at_ms: frames[0]?.timestampMs ?? null,
      ended_at_ms: frames.at(-1)?.timestampMs ?? null,
      inference_ms: inferenceMs,
      execution_provider: handle.provider,
      detail: inputDetail,
    };
  } catch (error) {
    lastError = error;
    dispatchStatus('unavailable', String(error?.message ?? error));
    return {
      status: 'unavailable',
      reason: 'inference_failed',
      detail: String(error?.message ?? error),
      word: null,
      confidence: 0,
      alternatives: [],
      model_version: MODEL_VERSION,
      frame_count: frames.length,
      captured_frame_count: captured.length,
      input_summary: inputSummary,
      started_at_ms: frames[0]?.timestampMs ?? null,
      ended_at_ms: frames.at(-1)?.timestampMs ?? null,
    };
  }
}

// Sign-by-sign names used by the live frontend. The older capture names stay
// exported for compatibility with existing tests and integrations.
export const beginAslSignCapture = beginAslCapture;
export const finishAslSignCapture = finishAslCapture;
export const resetAslSignCapture = resetAslCapture;

globalThis.signBridgeAslRecognizer = Object.freeze({
  prepare: prepareAslRecognizer,
  beginSignCapture: beginAslCapture,
  finishSignCapture: finishAslCapture,
  resetSignCapture: resetAslCapture,
  beginCapture: async () => {
    beginAslCapture();
  },
  finishCapture: finishAslCapture,
  teachLastCapture: async (label) => teachLastAslCapture(label),
  reset: async () => {
    resetAslCapture();
  },
  getStatus: () => ({status, model_version: MODEL_VERSION}),
});
