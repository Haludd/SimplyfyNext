import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const sourceUrl = new URL('../../web/asl_recognizer.js', import.meta.url);
const source = await readFile(sourceUrl, 'utf8');

async function recognizer() {
  const context = vm.createContext({
    console,
    CustomEvent: class {
      constructor(type, init) { this.type = type; this.detail = init.detail; }
    },
    document: {baseURI: 'http://localhost/'},
  });
  const module = new vm.SourceTextModule(source, {
    context,
    initializeImportMeta: (meta) => { meta.url = sourceUrl.href; },
  });
  await module.link(() => {});
  await module.evaluate();
  return module.namespace;
}

test('the browser adapter captures MediaPipe landmark frames locally', async () => {
  const api = await recognizer();
  api.beginAslCapture();
  api.ingestAslFrame({timestampMs: 1000, holisticResults: {}});
  api.ingestAslFrame({timestampMs: 1050, holisticResults: {}});
  const result = await api.finishAslCapture();

  assert.equal(result.status, 'unknown');
  assert.equal(result.model_version, 'signchat_asl_signs_onnx');
  assert.equal(result.frame_count, 2);
  assert.equal(result.reason, 'too_few_model_frames');
  assert.match(source, /asl-signs\.onnx/);
  assert.match(source, /beginSignCapture:\s*async/);
  assert.match(source, /resetSignCapture:\s*async/);
  assert.match(source, /inferenceTail/);
  assert.match(source, /enable_memory_arena_shrinkage/);
  assert.match(source, /tensor\.dispose/);
  assert.match(source, /MAX_CLASSIFIER_RUNS/);
  assert.match(source, /DISABLED_LABELS\s*=\s*new Set\(\['donkey'\]\)/);
  assert.match(source, /disabled_label/);
  assert.match(source, /session\.release/);
  assert.match(source, /capture inference error/);
  assert.doesNotMatch(source, /microsoft|stgcn|unisign|backend/i);
});

test('an unfinished capture is explicitly reset', async () => {
  const api = await recognizer();
  api.beginAslCapture();
  api.resetAslCapture();
  const result = await api.finishAslCapture();
  assert.equal(result.reason, 'no_active_capture');
});

test('completed capture frames never bleed into the next capture', async () => {
  const api = await recognizer();
  api.beginAslCapture();
  api.ingestAslFrame({timestampMs: 1000, holisticResults: {}});
  const first = await api.finishAslCapture();
  assert.equal(first.frame_count, 1);

  api.beginAslCapture();
  api.ingestAslFrame({timestampMs: 2000, holisticResults: {}});
  const second = await api.finishAslCapture();
  assert.equal(second.frame_count, 1);
});
