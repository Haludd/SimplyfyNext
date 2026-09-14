// Browser-local ASL classifier based on Signchat's PopSign 250 ONNX model.
//
// MediaPipe Holistic supplies the 543 landmark rows expected by the model.
// ONNX Runtime Web runs the 21 MB classifier in this tab; no camera frames or
// recognition requests leave the device.

const MODEL_VERSION = 'signchat_asl_signs_onnx';
const MODEL_PATH = 'models/asl-signs/asl-signs.onnx';
const LABELS_PATH = 'models/asl-signs/sign_to_prediction_index_map.json';
const ORT_VERSION = '1.20.1';
const ORT_MODULE_URL =
  `https://cdn.jsdelivr.net/npm/onnxruntime-web@${ORT_VERSION}/dist/ort.min.mjs`;
const ORT_WASM_PATH =
  `https://cdn.jsdelivr.net/npm/onnxruntime-web@${ORT_VERSION}/dist/`;

const FRAME_FLOATS = 543 * 3;
const MAX_CAPTURE_FRAMES = 48;
const MIN_CAPTURE_FRAMES = 8;
const CAPTURE_INTERVAL_MS = 50;
const MIN_CONFIDENCE = 0.4;
const MAX_CLASSIFIER_RUNS = 20;
const MAX_CLASSIFIER_AGE_MS = 5 * 60 * 1000;

// Keep the model's original 250-class index map intact, but never present
// disabled vocabulary items to the signer or sentence backend. A disabled
// top result becomes unknown instead of being silently replaced with the
// model's next guess.
const DISABLED_LABELS = new Set(['donkey']);

let captureActive = false;
let captureFrames = [];
let lastCapturedAtMs = Number.NEGATIVE_INFINITY;
let lastError;
let ortPromise;
let classifierPromise;
let inferenceTail = Promise.resolve();
let classifierRecycleTail = Promise.resolve();
let classifierRunCount = 0;
let classifierCreatedAtMs = 0;

// Ask ONNX Runtime Web's WASM allocator to release temporary arena blocks
// between isolated-word predictions. Without this, long sessions can retain
// activation buffers and gradually put the camera/tracker under memory
// pressure.
const INFERENCE_RUN_OPTIONS = {
  extra: {
    memory: {
      enable_memory_arena_shrinkage: '1',
    },
  },
};

function dispatchStatus(status, detail = '') {
  globalThis.dispatchEvent?.(
    new CustomEvent('signbridge-asl-status', {
      detail: JSON.stringify({status, model_version: MODEL_VERSION, detail}),
    }),
  );
}

function absoluteAssetUrl(path) {
  return new URL(path, document.baseURI).href;
}

async function loadOrt() {
  if (ortPromise) return ortPromise;
  const dynamicImport = new Function('url', 'return import(url)');
  ortPromise = dynamicImport(ORT_MODULE_URL).then((module) => {
    const ort = module.default ?? module;
    ort.env.wasm.wasmPaths = ORT_WASM_PATH;
    // SharedArrayBuffer is not guaranteed on every Flutter web deployment;
    // one WASM thread is the safest default and still keeps this model local.
    ort.env.wasm.numThreads = 1;
    return ort;
  });
  return ortPromise;
}

async function loadLabels() {
  const response = await fetch(absoluteAssetUrl(LABELS_PATH), {
    cache: 'force-cache',
  });
  if (!response.ok) {
    throw new Error(`ASL label map failed to load (${response.status})`);
  }
  const raw = await response.json();
  const indexToLabel = [];
  for (const [label, index] of Object.entries(raw)) {
    if (!Number.isInteger(index) || index < 0) {
      throw new Error(`Invalid ASL label index for ${label}`);
    }
    indexToLabel[index] = label;
  }
  if (indexToLabel.length !== 250 || indexToLabel.some((label) => !label)) {
    throw new Error('ASL label map must contain 250 contiguous labels');
  }
  return indexToLabel;
}

async function loadClassifier() {
  const [ort, labels, modelResponse] = await Promise.all([
    loadOrt(),
    loadLabels(),
    fetch(absoluteAssetUrl(MODEL_PATH), {cache: 'force-cache'}),
  ]);
  if (!modelResponse.ok) {
    throw new Error(`ASL model failed to load (${modelResponse.status})`);
  }
  const modelBytes = await modelResponse.arrayBuffer();
  let session;
  let executionProvider = 'wasm';
  if (globalThis.navigator?.gpu) {
    try {
      session = await ort.InferenceSession.create(modelBytes, {
        executionProviders: ['webgpu'],
        graphOptimizationLevel: 'all',
      });
      executionProvider = 'webgpu';
    } catch (webGpuError) {
      // Some browsers expose navigator.gpu but do not support every ONNX
      // operator used by this model. Keep the app usable with local WASM.
      console.warn('Signchat WebGPU unavailable; using local WASM instead', webGpuError);
    }
  }
  if (!session) {
    session = await ort.InferenceSession.create(modelBytes, {
      executionProviders: ['wasm'],
      graphOptimizationLevel: 'all',
    });
  }
  const inputName = session.inputNames[0];
  const outputName = session.outputNames[0];
  if (!inputName || !outputName) {
    throw new Error('ASL ONNX model did not expose input/output names');
  }
  classifierCreatedAtMs = Date.now();
  classifierRunCount = 0;
  return {ort, labels, session, inputName, outputName, executionProvider};
}

function ensureClassifier() {
  if (!classifierPromise) {
    dispatchStatus('loading', 'Loading local ASL model');
    classifierPromise = loadClassifier().then((classifier) => {
      dispatchStatus('ready', 'Local ASL model ready');
      return classifier;
    }).catch((error) => {
      lastError = error;
      dispatchStatus('error', error?.message ?? String(error));
      throw error;
    });
  }
  return classifierPromise;
}

function recycleClassifier(reason = 'scheduled refresh') {
  const task = classifierRecycleTail.then(async () => {
    const previousPromise = classifierPromise;
    classifierPromise = undefined;
    classifierRunCount = 0;
    classifierCreatedAtMs = 0;
    if (!previousPromise) return;
    try {
      const previous = await previousPromise;
      await previous.session.release?.();
    } catch (error) {
      // A failed session may already be partially released. The next call to
      // ensureClassifier() still creates a fresh session, so recovery continues.
      console.warn(`Signchat local model released after ${reason}`, error);
    }
  });
  classifierRecycleTail = task.catch(() => {});
  return task;
}

async function refreshClassifierIfNeeded() {
  await classifierRecycleTail;
  if (!classifierPromise) return;
  const age = Date.now() - classifierCreatedAtMs;
  if (classifierRunCount < MAX_CLASSIFIER_RUNS && age < MAX_CLASSIFIER_AGE_MS) {
    return;
  }
  dispatchStatus('loading', 'Refreshing local ASL model memory');
  await recycleClassifier('scheduled refresh');
}

function writeLandmarks(target, offset, landmarks, count) {
  if (!Array.isArray(landmarks)) return;
  const limit = Math.min(count, landmarks.length);
  for (let index = 0; index < limit; index += 1) {
    const point = landmarks[index];
    const base = (offset + index) * 3;
    if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) {
      continue;
    }
    target[base] = point.x;
    target[base + 1] = point.y;
    target[base + 2] = Number.isFinite(point.z) ? point.z : 0;
  }
}

// Kaggle/PopSign order: Face(468), Left hand(21), Pose(33), Right hand(21).
function frameFromHolistic(results) {
  const frame = new Float32Array(FRAME_FLOATS);
  frame.fill(Number.NaN);
  writeLandmarks(frame, 0, results?.faceLandmarks, 468);
  writeLandmarks(frame, 468, results?.leftHandLandmarks, 21);
  writeLandmarks(frame, 489, results?.poseLandmarks, 33);
  writeLandmarks(frame, 522, results?.rightHandLandmarks, 21);
  return frame;
}

function softmax(logits) {
  let max = Number.NEGATIVE_INFINITY;
  for (const value of logits) max = Math.max(max, value);
  const probabilities = new Float32Array(logits.length);
  let sum = 0;
  for (let index = 0; index < logits.length; index += 1) {
    const value = Math.exp(logits[index] - max);
    probabilities[index] = value;
    sum += value;
  }
  if (sum > 0) {
    for (let index = 0; index < probabilities.length; index += 1) {
      probabilities[index] /= sum;
    }
  }
  return probabilities;
}

function topK(probabilities, labels, count = 3, excludedLabels = new Set()) {
  return Array.from(probabilities)
    .map((confidence, index) => ({
      word: labels[index] ?? 'unknown',
      confidence,
      index,
    }))
    .filter((candidate) => !excludedLabels.has(candidate.word.toLowerCase()))
    .sort((left, right) => right.confidence - left.confidence)
    .slice(0, count)
    .map((candidate, index) => ({
      word: candidate.word,
      confidence: candidate.confidence,
      rank: index + 1,
    }));
}

async function runClassification(frames) {
  await refreshClassifierIfNeeded();
  const classifier = await ensureClassifier();
  classifierRunCount += 1;
  const flat = new Float32Array(frames.length * FRAME_FLOATS);
  frames.forEach((frame, index) => flat.set(frame, index * FRAME_FLOATS));
  const tensor = new classifier.ort.Tensor(
    'float32',
    flat,
    [frames.length, 543, 3],
  );
  let outputs;
  try {
    const started = performance.now();
    outputs = await classifier.session.run(
      {[classifier.inputName]: tensor},
      undefined,
      INFERENCE_RUN_OPTIONS,
    );
    const logitsTensor = outputs[classifier.outputName];
    if (!logitsTensor?.data) throw new Error('ASL ONNX output was empty');
    // softmax copies the values, so the runtime-owned output can be released
    // as soon as this prediction has been decoded.
    const probabilities = softmax(logitsTensor.data);
    const rawBest = topK(probabilities, classifier.labels, 1)[0];
    const topLabelDisabled = rawBest != null &&
      DISABLED_LABELS.has(rawBest.word.toLowerCase());
    const alternatives = topK(
      probabilities,
      classifier.labels,
      3,
      DISABLED_LABELS,
    );
    const best = alternatives[0];
    const status = !topLabelDisabled && best && best.confidence >= MIN_CONFIDENCE
      ? 'recognized'
      : 'unknown';
    return {
      status,
      word: status === 'recognized' ? best.word : null,
      confidence: best?.confidence ?? 0,
      alternatives,
      model_version: MODEL_VERSION,
      frame_count: frames.length,
      inference_ms: Math.round(performance.now() - started),
      reason: status === 'recognized'
        ? undefined
        : topLabelDisabled
          ? 'disabled_label'
          : 'low_confidence',
      detail: `${frames.length} MediaPipe landmark frames · local ${classifier.executionProvider} ONNX inference`,
    };
  } finally {
    // ONNX Runtime tensors own WASM/GPU-backed buffers. JavaScript GC is not
    // a reliable boundary for a long-running camera session, so release every
    // per-prediction tensor explicitly.
    tensor.dispose?.();
    for (const output of Object.values(outputs ?? {})) output?.dispose?.();
  }
}

// Keep ONNX Runtime calls single-filed. Automatic segmentation can finish a
// new sign while the previous result is still being decoded; overlapping
// session.run calls otherwise retain multiple WebAssembly/GPU buffers.
function classify(frames) {
  const run = inferenceTail.then(() => runClassification(frames));
  inferenceTail = run.catch(() => {});
  return run;
}

export function prepareAslRecognizer() {
  return ensureClassifier();
}

export function beginAslCapture() {
  captureActive = true;
  captureFrames = [];
  lastCapturedAtMs = Number.NEGATIVE_INFINITY;
  lastError = undefined;
  dispatchStatus('capturing');
}

export function resetAslCapture() {
  captureActive = false;
  captureFrames = [];
  lastCapturedAtMs = Number.NEGATIVE_INFINITY;
  dispatchStatus('ready');
}

export function ingestAslFrame({timestampMs, holisticResults}) {
  if (!captureActive || !holisticResults) return;
  const timestamp = Number.isFinite(Number(timestampMs))
    ? Number(timestampMs)
    : Date.now();
  if (timestamp - lastCapturedAtMs < CAPTURE_INTERVAL_MS) return;
  lastCapturedAtMs = timestamp;
  captureFrames.push(frameFromHolistic(holisticResults));
  if (captureFrames.length > MAX_CAPTURE_FRAMES) captureFrames.shift();
}

export async function finishAslCapture() {
  if (!captureActive) {
    return {
      status: 'unknown',
      reason: 'no_active_capture',
      word: null,
      confidence: 0,
      alternatives: [],
      model_version: MODEL_VERSION,
      frame_count: 0,
    };
  }
  captureActive = false;
  const frames = captureFrames.slice();
  captureFrames = [];
  lastCapturedAtMs = Number.NEGATIVE_INFINITY;
  dispatchStatus('processing', 'Running local ASL model');
  if (frames.length < MIN_CAPTURE_FRAMES) {
    return {
      status: 'unknown',
      reason: 'too_few_model_frames',
      word: null,
      confidence: 0,
      alternatives: [],
      model_version: MODEL_VERSION,
      frame_count: frames.length,
      detail: `Need at least ${MIN_CAPTURE_FRAMES} landmark frames.`,
    };
  }
  try {
    const result = await classify(frames);
    dispatchStatus(result.status, result.detail);
    return result;
  } catch (error) {
    lastError = error;
    dispatchStatus('error', error?.message ?? String(error));
    await recycleClassifier('inference error');
    return {
      status: 'unavailable',
      reason: 'local_model_error',
      word: null,
      confidence: 0,
      alternatives: [],
      model_version: MODEL_VERSION,
      frame_count: frames.length,
      detail: error?.message ?? String(error),
    };
  }
}

export const beginAslSignCapture = beginAslCapture;
export const finishAslSignCapture = finishAslCapture;
export const resetAslSignCapture = resetAslCapture;

globalThis.signBridgeLocalAslClassifier = Object.freeze({
  prepare: prepareAslRecognizer,
  // The Dart bridge awaits these methods, so keep the browser API Promise-
  // based even though beginning/resetting a capture is synchronous internally.
  beginSignCapture: async () => beginAslCapture(),
  finishSignCapture: finishAslCapture,
  resetSignCapture: async () => resetAslCapture(),
  beginCapture: async () => beginAslCapture(),
  finishCapture: finishAslCapture,
  reset: async () => resetAslCapture(),
  getStatus: () => ({
    status: captureActive ? 'capturing' : 'ready',
    model_version: MODEL_VERSION,
    detail: lastError?.message,
  }),
});
