// Browser-local inference adapter for the Google ASL 25-word model.
//
// The tracker calls `ingestAslFrame()` with MediaPipe's complete landmark
// arrays for every valid Holistic frame. A source-compatible rolling window
// remains in this page: only the final word and its confidence are returned
// to Dart.
//
// The model is deliberately loaded from the app, while ONNX Runtime is pinned
// to a CDN just like the existing MediaPipe Tasks runtime. This keeps model
// execution local to the browser and avoids sending camera frames or landmark
// sequences to a classifier service.
const WASM_RUNTIME_URL =
  'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/ort.wasm.bundle.min.mjs';
const WEBGPU_RUNTIME_URL =
  'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.22.0/dist/ort.webgpu.bundle.min.mjs';

const MODEL_URL = new URL(
  './models/google_asl_25_v20250723_042752.onnx',
  import.meta.url,
).toString();

// The exported upstream model has a fixed input tensor:
// [batch, 16 frames, 543 landmarks, x/y/z]. Its landmark ordering is
// FaceMesh(468), Pose(33), left hand(21), then right hand(21).
const TARGET_FRAMES = 16;
const FACE_POINTS = 468;
const POSE_POINTS = 33;
const HAND_POINTS = 21;
const VALUES_PER_POINT = 3;
const MODEL_LANDMARKS_PER_FRAME =
  FACE_POINTS + POSE_POINTS + HAND_POINTS + HAND_POINTS;
const VALUES_PER_FRAME = MODEL_LANDMARKS_PER_FRAME * VALUES_PER_POINT;
// The upstream Python utility has a dynamic time axis and can predict after
// five frames. This browser export has a static 16-frame ONNX input, so do
// not invent a full temporal sequence by repeating five frames: wait for the
// complete model window, then select it exactly like np.linspace(..., 16).
const MIN_MODEL_CAPTURED_FRAMES = TARGET_FRAMES;
const MIN_TEMPLATE_CAPTURED_FRAMES = 5;
const MAX_CAPTURED_FRAMES = 30;
const CAPTURE_SAMPLE_INTERVAL_MS = 0;
const ACTIVE_MOTION_THRESHOLD = 0.003;
const ACTIVE_LEADING_CONTEXT_FRAMES = 2;
const ACTIVE_TRAILING_CONTEXT_FRAMES = 4;
const MIN_CONFIDENCE = 0.6;
const MIN_CONFIDENCE_MARGIN = 0.08;
const MODEL_VERSION = 'google_asl_25_v20250723_042752';

// These are the exact feature indices selected by the checkpoint's
// PreprocessingLayer. It consumes the 543-slot MediaPipe tensor, but its
// learned features use these 20 face entries and the two complete hands; pose
// slots are retained only to preserve the trained tensor's indexing.
const MODEL_FACE_FEATURE_POINTS = [
  33, 133, 362, 263, 61, 291, 199, 419, 17, 84, 17, 314, 405, 320, 307,
  375, 321, 308, 324, 318,
];
const MODEL_FEATURE_POINTS_PER_FRAME =
  MODEL_FACE_FEATURE_POINTS.length + HAND_POINTS + HAND_POINTS;

const LABELS = [
  'hello',
  'please',
  'thankyou',
  'bye',
  'mom',
  'dad',
  'boy',
  'girl',
  'man',
  'child',
  'drink',
  'sleep',
  'go',
  'happy',
  'sad',
  'hungry',
  'thirsty',
  'sick',
  'bad',
  'red',
  'blue',
  'green',
  'yellow',
  'black',
  'white',
];

// A correction is intentionally keyed to a local motion template, not to a
// model label. For example, a person can teach their own `bye` motion after a
// mistaken `blue` result without making every genuine blue sign say `bye`.
// Templates contain normalized landmark coordinates only and never leave this
// browser unless the user independently chooses to submit a final word.
// v2 is model-aligned: old v1 hand-only templates remain untouched in browser
// storage, but are not mixed with this incompatible feature representation.
const PERSONAL_TEMPLATE_STORAGE_KEY = 'signbridge.asl.personal-templates.v2';
const PERSONAL_TEMPLATE_SAMPLES_PER_WORD = 5;
const PERSONAL_TEMPLATE_DEFAULT_MAX_DISTANCE = 0.6;
const PERSONAL_TEMPLATE_MIN_MAX_DISTANCE = 0.4;
const PERSONAL_TEMPLATE_MAX_MAX_DISTANCE = 0.85;
const PERSONAL_TEMPLATE_AMBIGUITY_MARGIN = 0.08;
const PERSONAL_TEMPLATE_SIGNATURE_LENGTH =
  TARGET_FRAMES * MODEL_FEATURE_POINTS_PER_FRAME * 3;

let sessionPromise;
let captureActive = false;
let rollingFrames = [];
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
  return point && finiteNumber(point.x) && finiteNumber(point.y);
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

function packFrame({faceLandmarks, poseLandmarks, leftHand, rightHand}) {
  const values = new Float32Array(VALUES_PER_FRAME);
  copyPoints(values, 0, faceLandmarks, FACE_POINTS);
  copyPoints(values, FACE_POINTS, poseLandmarks, POSE_POINTS);
  copyPoints(values, FACE_POINTS + POSE_POINTS, leftHand, HAND_POINTS);
  copyPoints(
    values,
    FACE_POINTS + POSE_POINTS + HAND_POINTS,
    rightHand,
    HAND_POINTS,
  );
  return values;
}

function resampleFrames(frames) {
  const output = new Float32Array(TARGET_FRAMES * VALUES_PER_FRAME);
  const lastIndex = frames.length - 1;
  for (let targetIndex = 0; targetIndex < TARGET_FRAMES; targetIndex += 1) {
    // The upstream Python implementation uses np.linspace(..., dtype=int),
    // which truncates non-negative indices. Matching that selection exactly
    // avoids shifting the model's temporal motion features by one frame.
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
  return x !== 0 || y !== 0 || z !== 0;
}

function averageHandMotion(previous, current) {
  const handOffsets = [
    (FACE_POINTS + POSE_POINTS) * VALUES_PER_POINT,
    (FACE_POINTS + POSE_POINTS + HAND_POINTS) * VALUES_PER_POINT,
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

  const start = Math.max(0, firstActive - ACTIVE_LEADING_CONTEXT_FRAMES);
  const end = Math.min(
    frames.length,
    lastActive + ACTIVE_TRAILING_CONTEXT_FRAMES + 1,
  );
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
  const leftHandStart = FACE_POINTS + POSE_POINTS;
  const rightHandStart = leftHandStart + HAND_POINTS;
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
    `face + ${summary.model_hand_feature_points} hand · hands L ${summary.left_hand_tracked_frames}/` +
    `${summary.selected_frames} R ${summary.right_hand_tracked_frames}/` +
    `${summary.selected_frames}`
  );
}

function normalizedPersonalLabel(value) {
  const label = String(value ?? '').trim().toLowerCase();
  return label.length > 0 && label.length <= 80 ? label : null;
}

function pointOffset(frameOffset, pointIndex) {
  return frameOffset + pointIndex * VALUES_PER_POINT;
}

function completedCaptureSignature(frames) {
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
        x: values[offset],
        y: values[offset + 1],
        present: hasTrackedHandPoint(values, offset),
      });
    };
    for (const pointIndex of MODEL_FACE_FEATURE_POINTS) {
      appendFeature(pointIndex);
    }
    for (let pointIndex = 0; pointIndex < HAND_POINTS; pointIndex += 1) {
      appendFeature(FACE_POINTS + POSE_POINTS + pointIndex);
    }
    for (let pointIndex = 0; pointIndex < HAND_POINTS; pointIndex += 1) {
      appendFeature(
        FACE_POINTS + POSE_POINTS + HAND_POINTS + pointIndex,
      );
    }
    featureFrames.push(features);
  }

  // Mirror the checkpoint's PreprocessingLayer: normalize x/y against the
  // sequence mean of face point 17, then use the selected-feature sequence
  // standard deviation. Presence is an extra local-template signal only; the
  // neural model itself still receives the original 543-slot tensor.
  faceAnchorX /= TARGET_FRAMES;
  faceAnchorY /= TARGET_FRAMES;
  const featureCount = TARGET_FRAMES * MODEL_FEATURE_POINTS_PER_FRAME;
  let xSquaredDistance = 0;
  let ySquaredDistance = 0;
  for (const features of featureFrames) {
    for (const feature of features) {
      xSquaredDistance += (feature.x - faceAnchorX) ** 2;
      ySquaredDistance += (feature.y - faceAnchorY) ** 2;
    }
  }
  const varianceDivisor = Math.max(1, featureCount - 1);
  const xScale = Math.sqrt(xSquaredDistance / varianceDivisor) || 1;
  const yScale = Math.sqrt(ySquaredDistance / varianceDivisor) || 1;
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

function softmax(logits) {
  const maximum = Math.max(...logits);
  const exponentials = logits.map((value) => Math.exp(value - maximum));
  const total = exponentials.reduce((sum, value) => sum + value, 0);
  return exponentials.map((value) => value / total);
}

function rankedPredictions(logits) {
  const probabilities = softmax(Array.from(logits));
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

async function createSessionWithRuntime(runtime, provider) {
  if (provider === 'wasm') {
    // Flutter's development server is not cross-origin isolated, so use one
    // WASM thread there. Isolated production deployments can use a second
    // worker without oversubscribing lower-powered phones.
    runtime.env.wasm.numThreads = globalThis.crossOriginIsolated
      ? Math.min(2, globalThis.navigator?.hardwareConcurrency ?? 1)
      : 1;
    runtime.env.wasm.proxy = false;
  }
  const session = await runtime.InferenceSession.create(MODEL_URL, {
    executionProviders: [provider],
    graphOptimizationLevel: 'all',
  });
  // Compile and allocate before the signer finishes their first word. The
  // fixed tensor shape makes this warm-up representative without exposing
  // real landmark data to any other component.
  const warmup = new runtime.Tensor(
    'float32',
    new Float32Array(TARGET_FRAMES * VALUES_PER_FRAME),
    [1, TARGET_FRAMES, FACE_POINTS + POSE_POINTS + 2 * HAND_POINTS, 3],
  );
  await session.run({landmarks: warmup});
  return {session, runtime, provider};
}

async function createSession() {
  dispatchStatus('loading', 'Preparing local ASL model');
  let handle;
  if (globalThis.navigator?.gpu) {
    try {
      const webgpuRuntime = await import(WEBGPU_RUNTIME_URL);
      handle = await createSessionWithRuntime(webgpuRuntime, 'webgpu');
    } catch (error) {
      // Some browsers expose WebGPU but cannot execute every operator in this
      // temporal model. Fall back without making recognition unavailable.
      console.info('Local ASL WebGPU unavailable; using WASM.', error);
    }
  }
  if (!handle) {
    const wasmRuntime = await import(WASM_RUNTIME_URL);
    handle = await createSessionWithRuntime(wasmRuntime, 'wasm');
  }
  lastError = undefined;
  dispatchStatus('ready', `Local ASL model ready (${handle.provider})`);
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
  captureActive = true;
  // Begin loading as early as possible so an ordinary one-second sign does
  // not have to wait for the model download after the signer has finished.
  void prepareAslRecognizer().catch(() => {});
}

export function resetAslCapture() {
  captureActive = false;
  rollingFrames = [];
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
  if (subjectTracking?.locked !== true) return;
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
  if (recordedAtMs - lastCapturedAtMs < CAPTURE_SAMPLE_INTERVAL_MS) return;
  lastCapturedAtMs = recordedAtMs;
  rollingFrames.push({
    timestampMs: recordedAtMs,
    values: packFrame({faceLandmarks, poseLandmarks, leftHand, rightHand}),
  });
  if (rollingFrames.length > MAX_CAPTURED_FRAMES) rollingFrames.shift();
}

export async function finishAslCapture() {
  captureActive = false;
  // Match the upstream live recognizer: predict from the latest continuous
  // 30-frame Holistic buffer. Do not cut this to just the detected movement;
  // the model was trained with its leading/trailing temporal context.
  const captured = rollingFrames.slice(-MAX_CAPTURED_FRAMES);
  const frames = captured;
  // Personal corrections retain their own movement-focused signature so a
  // previously taught sign remains stable across naturally longer pauses.
  const templateFrames = activeMotionFrames(captured);
  const inputSummary = modelInputSummary(frames, captured.length);
  const inputDetail = modelInputDetail(inputSummary);
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
        `Personal model-aligned template · distance ${personalMatch.distance.toFixed(3)}/` +
        `${personalMatch.threshold.toFixed(3)} · ` +
        inputDetail,
      execution_provider: 'personal_template',
    };
  }

  let handle;
  try {
    handle = await prepareAslRecognizer();
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
    const tensor = new handle.runtime.Tensor(
      'float32',
      resampleFrames(frames),
      [1, TARGET_FRAMES, FACE_POINTS + POSE_POINTS + 2 * HAND_POINTS, 3],
    );
    const outputs = await handle.session.run({landmarks: tensor});
    const alternatives = rankedPredictions(outputs.logits.data);
    const best = alternatives[0];
    const runnerUp = alternatives[1];
    const inferenceMs = Math.round(performance.now() - startedAt);
    const isAmbiguous =
      runnerUp && best && best.confidence - runnerUp.confidence < MIN_CONFIDENCE_MARGIN;
    if (!best || best.confidence < MIN_CONFIDENCE || isAmbiguous) {
      return {
        ...unknownOutcome(isAmbiguous ? 'ambiguous_prediction' : 'low_confidence', frames),
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

globalThis.signBridgeAslRecognizer = Object.freeze({
  prepare: prepareAslRecognizer,
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
