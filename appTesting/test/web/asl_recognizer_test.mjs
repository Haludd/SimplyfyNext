import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const sourceUrl = new URL('../../web/asl_recognizer.js', import.meta.url);
const source = await readFile(sourceUrl, 'utf8');
const manifest = JSON.parse(await readFile(new URL('../../web/models/jamesbustos_asl_250_809d456.manifest.json', import.meta.url)));
const point = (index, x = .4) => ({x: x + index * .0001, y: .35 + index * .0002, z: -.01, visibility: .95});
const frame = (timestampMs, x = .4, side = 'right') => ({
  timestampMs,
  faceLandmarks: Array.from({length: 468}, (_, i) => point(i)),
  poseLandmarks: Array.from({length: 33}, (_, i) => point(i)),
  leftHand: side === 'left' ? Array.from({length: 21}, (_, i) => point(i, x)) : [],
  rightHand: side === 'right' ? Array.from({length: 21}, (_, i) => point(i, x)) : [],
  subjectTracking: {locked: true, visible: true},
});

async function recognizer({run, query = ''} = {}) {
  const feeds = [];
  const events = [];
  const storage = new Map();
  const context = vm.createContext({
    console, URL, URLSearchParams, Float32Array, performance, setTimeout,
    addEventListener() {},
    location: {search: query}, navigator: {},
    window: {dispatchEvent: (event) => events.push(event), addEventListener() {}},
    document: {addEventListener() {}, createElement: () => ({getContext: () => null})},
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init.detail; } },
    localStorage: {getItem: (key) => storage.get(key), setItem: (key, value) => storage.set(key, value)},
    fetch: async () => ({ok: true, json: async () => structuredClone(manifest)}),
  });
  const runtime = new vm.SyntheticModule(['createAslModelHandle'], function () {
    this.setExport('createAslModelHandle', async () => ({
      provider: 'tflite_wasm', dispose() {},
      predict: async (values) => {
        feeds.push(values);
        if (run && feeds.length > 2) return run(values);
        const data = new Float32Array(250).fill(.01 / 249);
        data[manifest.labels.indexOf('hello')] = .99;
        return data; // Transport/label test only, not an accuracy benchmark.
      },
    }));
  }, {context});
  await runtime.link(() => {});
  await runtime.evaluate();
  const module = new vm.SourceTextModule(source, {
    context,
    initializeImportMeta: (meta) => { meta.url = sourceUrl.href; },
    importModuleDynamically: async () => runtime,
  });
  await module.link(() => runtime);
  await module.evaluate();
  return {api: module.namespace, module, context, feeds, events, storage};
}

function capture(api, count = 40, {start = 1000, side = 'right', move = true} = {}) {
  api.beginAslCapture();
  for (let i = 0; i < count; i++) api.ingestAslFrame(frame(start + i * 34, move ? .3 + i * .004 : .4, side));
}

test('manifest locks the 543-point tensor, hand slots and label order', async () => {
  const {api} = await recognizer();
  api.validateModelManifest(manifest);
  for (const changed of [
    {...manifest, labels: [...manifest.labels].reverse()},
    {...manifest, input_shape: [1, 30, 543, 3]},
    {...manifest, landmark_order: ['hands', 'face', 'pose']},
  ]) assert.throws(() => api.validateModelManifest(changed), /manifest/);
});

test('packing keeps raw x/y/z and the native right-hand slot when left is absent', async () => {
  const {api} = await recognizer();
  const input = frame(0, .7);
  const packed = api.packFrame(input);
  assert.equal(packed.length, 543 * 3);
  assert.ok(Number.isNaN(packed[468 * 3]));
  assert.ok(Math.abs(packed[489 * 3] - input.poseLandmarks[0].x) < 1e-6);
  assert.ok(Math.abs(packed[522 * 3] - .7) < 1e-6);
  assert.ok(Math.abs(packed[522 * 3 + 1] - .35) < 1e-6);
  assert.ok(Math.abs(packed[522 * 3 + 2] + .01) < 1e-6);
  input.leftHand = input.rightHand;
  input.rightHand = [];
  const left = api.packFrame(input);
  assert.ok(Math.abs(left[468 * 3] - .7) < 1e-6);
  assert.ok(Number.isNaN(left[522 * 3]));
});

test('30-frame sampling retains the entire sign in temporal order', async () => {
  const {api} = await recognizer();
  const frames = Array.from({length: 60}, (_, i) => ({values: new Float32Array(543 * 3).fill(i)}));
  const result = api.resampleFrames(frames);
  assert.deepEqual(Array.from({length: 30}, (_, i) => result[i * 543 * 3]),
    [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 59]);
});

test('completed sign preserves onset through a long trailing pause and emits hello', async () => {
  const {api, feeds} = await recognizer();
  await api.prepareAslRecognizer();
  capture(api, 40);
  for (let i = 40; i < 70; i++) api.ingestAslFrame(frame(1000 + i * 34, .3 + 39 * .004));
  const result = await api.finishAslCapture();
  assert.equal(result.word, 'hello');
  assert.equal(result.status, 'recognized');
  assert.equal(result.captured_frame_count, 70);
  assert.ok(result.frame_count < 50);
  assert.equal(feeds.at(-1).length, 30 * 543 * 3);
  assert.ok(Math.abs(feeds.at(-1)[522 * 3] - .3) < 1e-6);
  assert.equal((await api.finishAslCapture()).reason, 'no_active_capture');
});

test('consecutive captures are emitted as independent signs', async () => {
  let prediction = 0;
  const {api} = await recognizer({run: async (_values) => {
    const scores = new Float32Array(250).fill(.01 / 249);
    const label = prediction++ === 0 ? 'hello' : 'water';
    scores[manifest.labels.indexOf(label)] = .99;
    return scores;
  }});
  // Each completed pause closes one capture. Starting the next sign must not
  // reuse frames or merge the two model windows.
  capture(api, 40, {start: 1000});
  const first = await api.finishAslCapture();
  capture(api, 40, {start: 4000});
  const second = await api.finishAslCapture();
  assert.equal(first.word, 'hello');
  assert.equal(second.word, 'water');
  assert.notEqual(first.started_at_ms, second.started_at_ms);
});

test('previous capture and idle frames cannot fill a new short sign', async () => {
  const {api} = await recognizer();
  capture(api);
  await api.finishAslCapture();
  capture(api, 5, {start: 4000});
  assert.equal((await api.finishAslCapture()).status, 'unknown');
  assert.equal(api.teachLastAslCapture('hello').status, 'no_capture');
});

test('duplicate timestamps, absent hands and interrupted tracking cannot produce a word', async () => {
  for (const mode of ['duplicates', 'absent', 'gap']) {
    const {api, feeds} = await recognizer();
    await api.prepareAslRecognizer();
    api.beginAslCapture();
    for (let i = 0; i < 25; i++) {
      const time = mode === 'duplicates' ? 1000 : 1000 + i * 34 + (mode === 'gap' && i > 12 ? 1000 : 0);
      api.ingestAslFrame(frame(time, .3 + i * .004, mode === 'absent' ? 'none' : 'right'));
    }
    assert.equal((await api.finishAslCapture()).status, 'unknown', mode);
    assert.equal(feeds.length, 2, 'only the allocation and validation warmups may run');
  }
});

test('reset cancels an outstanding inference', async () => {
  let finish;
  const {api} = await recognizer({run: async () => new Promise((resolve) => { finish = resolve; })});
  await api.prepareAslRecognizer();
  capture(api);
  const pending = api.finishAslCapture();
  await new Promise((resolve) => setTimeout(resolve, 0));
  api.resetAslCapture();
  finish(new Float32Array(250).fill(1 / 250));
  assert.equal((await pending).reason, 'capture_cancelled');
  assert.equal(api.teachLastAslCapture('hello').status, 'no_capture');
});

test('malformed or ambiguous model scores are never accepted', async () => {
  const {api} = await recognizer();
  assert.throws(() => api.rankedPredictions([1, 2]), /250 finite probabilities/);
  assert.throws(() => api.rankedPredictions(new Float32Array(250).fill(NaN)), /finite probabilities/);
  assert.throws(() => api.rankedPredictions(new Float32Array(250)), /sum to one/);
  assert.throws(() => api.rankedPredictions(new Float32Array(250).fill(-1)), /finite probabilities/);
  const other = await recognizer({run: async () => new Float32Array(250).fill(1 / 250)});
  capture(other.api);
  assert.equal((await other.api.finishAslCapture()).status, 'unknown');
});

test('probabilities retain confidence and decode the full replacement vocabulary', async () => {
  const {api} = await recognizer();
  for (const word of ['TV', 'water', 'hello', 'please', 'zipper']) {
    const scores = new Float32Array(250).fill(.2 / 249);
    scores[manifest.labels.indexOf(word)] = .8;
    const best = api.rankedPredictions(scores)[0];
    assert.equal(best.word, word);
    assert.equal(best.confidence, .8, 'no second softmax');
  }
});

test('sub-threshold predictions do not become accepted words', async () => {
  const {api} = await recognizer({run: async () => {
    const scores = new Float32Array(250).fill(.31 / 249);
    scores[manifest.labels.indexOf('water')] = .69;
    return scores;
  }});
  capture(api);
  const result = await api.finishAslCapture();
  assert.equal(result.status, 'unknown');
  assert.equal(result.reason, 'low_confidence');
  assert.equal(result.word, null);
  assert.equal(result.alternatives[0].word, 'water');
});

test('a high-confidence top class is accepted without an arbitrary runner-up margin', async () => {
  const {api} = await recognizer({run: async () => {
    const scores = new Float32Array(250).fill(.08 / 248);
    scores[manifest.labels.indexOf('water')] = .72;
    scores[manifest.labels.indexOf('hello')] = .20;
    return scores;
  }});
  capture(api);
  const result = await api.finishAslCapture();
  assert.equal(result.status, 'recognized');
  assert.equal(result.word, 'water');
  assert.equal(result.confidence, .72);
});

test('overflow cannot hide a long capture by dropping its first frames', async () => {
  const {api} = await recognizer();
  capture(api, 200);
  assert.equal((await api.finishAslCapture()).reason, 'capture_too_long');
  capture(api, 40, {start: 10000});
  assert.equal((await api.finishAslCapture()).status, 'recognized');
});

test('old-model personal templates cannot override the replacement', async () => {
  const {api, storage} = await recognizer();
  capture(api);
  await api.finishAslCapture();
  api.teachLastAslCapture('water');
  const newKey = 'signbridge.asl.jamesbustos-250.templates.v1';
  storage.set('signbridge.asl.personal-templates.v3', storage.get(newKey));
  storage.delete(newKey);
  capture(api, 40, {start: 4000});
  assert.equal((await api.finishAslCapture()).word, 'hello');
  assert.ok(storage.has('signbridge.asl.personal-templates.v3'));
});

test('personal normalization handles absent NaN hands without storing NaNs', async () => {
  const {api} = await recognizer();
  const frames = Array.from({length: 30}, (_, i) => ({values: api.packFrame(frame(i * 34, .2 + i * .01))}));
  const signature = api.completedCaptureSignature(frames);
  assert.equal(signature.length, 30 * 55 * 3);
  assert.ok(signature.every(Number.isFinite));
  // Missing left hand is encoded as absent in the private template signature.
  assert.equal(signature[13 * 3 + 2], 0);
  assert.equal(signature[(13 + 21) * 3 + 2], 1);
});

test('personal correction remains local and only accepts model vocabulary', async () => {
  const {api, storage} = await recognizer();
  capture(api);
  await api.finishAslCapture();
  assert.equal(api.teachLastAslCapture('made-up-word').status, 'invalid_label');
  assert.equal(api.teachLastAslCapture('hello').status, 'stored');
  assert.ok(storage.has('signbridge.asl.jamesbustos-250.templates.v1'));
});

test('tracker defaults to 30 FPS and emits every backend face slot and real geometry', async () => {
  const h = await recognizer();
  const trackerSource = await readFile(new URL('../../web/hand_tracking.js', import.meta.url), 'utf8');
  const tracker = new vm.SourceTextModule(trackerSource + `\nexport {TRACKING_FPS, dispatchFrame, holisticResultAsTaskResults};\nvideo = {videoWidth: 640, videoHeight: 480};`, {context: h.context});
  await tracker.link(() => h.module);
  await tracker.evaluate();
  assert.equal(tracker.namespace.TRACKING_FPS, 30);
  const raw = frame(1000, .6);
  const hands = tracker.namespace.holisticResultAsTaskResults({rightHandLandmarks: raw.rightHand});
  const subject = {locked: true, visible: true, landmarks: raw.poseLandmarks,
    minX: 0, maxX: 1, minY: 0, maxY: 1, faceX: .42, faceY: .39, missingFrames: 0};
  tracker.namespace.dispatchFrame(hands, {}, {faceLandmarks: [raw.faceLandmarks]}, 1000, subject);
  const output = JSON.parse(h.events.find((e) => e.type === 'signbridge-hand-frame').detail);
  assert.deepEqual(output.camera, {source_width:640,source_height:480,rotation_degrees:0,mirrored_input:false,coordinates_canonical:true});
  assert.equal(output.hands[0].handedness, 'right');
  assert.equal(output.hands[0].landmarks[0].x, .6);
  const indices = new Set([...output.landmark_worlds.face.upper, ...output.landmark_worlds.face.mouth].map((p) => p.index));
  for (const i of [1,152,70,105,107,336,334,300,159,145,386,374,61,13,14,291]) assert.ok(indices.has(i), `missing backend face index ${i}`);
});
