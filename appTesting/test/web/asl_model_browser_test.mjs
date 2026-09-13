import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {fileURLToPath} from 'node:url';
import {resolve, sep} from 'node:path';
import test from 'node:test';
import {chromium} from 'playwright';

const app = resolve(fileURLToPath(new URL('../../', import.meta.url)));
const reference = JSON.parse(await readFile(new URL('../fixtures/asl_model_reference.json', import.meta.url)));
const manifest = JSON.parse(await readFile(new URL('../../web/models/jamesbustos_asl_250_809d456.manifest.json', import.meta.url)));

test('real browser model matches upstream TFLite across seven landmark cases', {timeout: 60000}, async (t) => {
  const server = createServer(async (request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    if (pathname === '/') {
      response.setHeader('Content-Type', 'text/html');
      response.end('<!doctype html><title>ASL browser verification</title>');
      return;
    }
    const path = resolve(app, '.' + decodeURIComponent(pathname));
    if (!path.startsWith(app + sep)) { response.writeHead(403).end(); return; }
    try {
      const data = await readFile(path);
      const type = path.endsWith('.js') ? 'text/javascript' : path.endsWith('.json')
        ? 'application/json' : path.endsWith('.wasm') ? 'application/wasm' : 'application/octet-stream';
      response.setHeader('Content-Type', type);
      response.end(data);
    } catch (_) { response.writeHead(404).end(); }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.CHROME_PATH ? {executablePath: process.env.CHROME_PATH} : {}),
  });
  t.after(() => browser.close());
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  // All inference assets must work with external network requests blocked.
  await page.route('**/*', (route) => new URL(route.request().url()).hostname === '127.0.0.1'
    ? route.continue() : route.abort());
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const actual = await page.evaluate(async (cases) => {
    const api = await import('/web/asl_recognizer.js');
    const handle = await api.prepareAslRecognizer();
    const point = (index, x) => ({x: x + index * .0001, y: .35 + index * .0002, z: -.01, visibility: .95});
    const points = (count, x) => Array.from({length: count}, (_, index) => point(index, x));
    const rawFrame = (name, index) => ({
      timestampMs: 1000 + index * 34,
      faceLandmarks: ['empty', 'missing_face'].includes(name) ? [] : points(468, .4),
      poseLandmarks: ['empty', 'missing_pose'].includes(name) ? [] : points(33, .4),
      leftHand: ['left', 'both'].includes(name) ? points(21, .6 - index * .002) : [],
      rightHand: ['empty', 'left'].includes(name) ? [] : points(21, name === 'stationary' ? .3 : .3 + index * .004),
      subjectTracking: {locked: true, visible: true},
    });
    const results = [];
    // Alternating inputs on the same session catch stale outputs and leaked LSTM state.
    const before = globalThis.tf.memory().numTensors;
    for (const name of [...cases, ...cases.toReversed()]) {
      const frames = Array.from({length: 30}, (_, index) => ({values: api.packFrame(rawFrame(name, index))}));
      const scores = await handle.predict(api.resampleFrames(frames));
      results.push({name, scores: Array.from(scores)});
    }
    api.beginAslCapture();
    for (let index = 0; index < 30; index++) api.ingestAslFrame(rawFrame('right', index));
    const result = await api.finishAslCapture();
    const vocabulary = ['water', 'hello', 'please', 'TV'].map((label) => api.teachLastAslCapture(label));
    return {results, result, vocabulary, before, after: globalThis.tf.memory().numTensors,
      status: globalThis.signBridgeAslRecognizer.getStatus()};
  }, reference.cases.map((entry) => entry.name));
  let maximumError = 0;
  for (const {name, scores} of actual.results) {
    const expected = reference.cases.find((entry) => entry.name === name).probabilities;
    assert.equal(scores.length, 250);
    for (let index = 0; index < scores.length; index++) {
      const error = Math.abs(scores[index] - expected[index]);
      maximumError = Math.max(maximumError, error);
      assert.ok(Number.isFinite(scores[index]) && error < 1e-5, `${name}[${index}] error=${error}`);
    }
  }
  const expectedScores = reference.cases.find((entry) => entry.name === 'right').probabilities;
  const bestIndex = expectedScores.indexOf(Math.max(...expectedScores));
  assert.equal(actual.result.model_version, manifest.model_id);
  assert.equal(actual.result.alternatives[0].word, manifest.labels[bestIndex]);
  assert.ok(Math.abs(actual.result.confidence - expectedScores[bestIndex]) < 1e-5);
  assert.equal(actual.result.input_summary.model_frames, 30);
  assert.equal(actual.result.input_summary.left_hand_tracked_frames, 0);
  assert.equal(actual.result.input_summary.right_hand_tracked_frames, 30);
  assert.equal(actual.result.execution_provider, 'tflite_wasm');
  assert.ok(actual.vocabulary.every((receipt) => receipt.status === 'stored'));
  assert.equal(actual.vocabulary[3].label, 'TV');
  assert.equal(actual.before, actual.after, 'TFJS tensors must not leak across predictions');
  assert.equal(actual.status.status, 'ready');
  assert.deepEqual(errors, []);
  t.diagnostic(`14 browser/native comparisons; maximum probability error ${maximumError}`);
});
