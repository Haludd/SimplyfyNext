import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const sourceUrl = new URL(
  '../../web/landmark_persistence.js',
  import.meta.url,
);
const source = await readFile(sourceUrl, 'utf8');
const trackerSource = await readFile(
  new URL('../../web/hand_tracking.js', import.meta.url),
  'utf8',
);

async function persistenceModule() {
  const context = vm.createContext({console});
  const module = new vm.SourceTextModule(source, {
    context,
    initializeImportMeta: (meta) => {
      meta.url = sourceUrl.href;
    },
  });
  await module.link(() => {});
  await module.evaluate();
  return module.namespace;
}

function posePoint(x, y, visibility = 0.95) {
  return {x, y, z: 0, visibility, presence: visibility};
}

function poseFrame({
  offsetX = 0,
  shoulders = true,
  shoulderHalfWidth = 0.1,
} = {}) {
  const points = Array(33).fill(null);
  points[0] = posePoint(0.5 + offsetX, 0.2);
  points[11] = shoulders
    ? posePoint(0.5 - shoulderHalfWidth + offsetX, 0.4)
    : null;
  points[12] = shoulders
    ? posePoint(0.5 + shoulderHalfWidth + offsetX, 0.4)
    : null;
  points[23] = posePoint(0.44 + offsetX, 0.7);
  points[24] = posePoint(0.56 + offsetX, 0.7);
  return points;
}

function faceFrame() {
  return Array.from({length: 468}, (_, index) => ({
    x: 0.42 + (index % 12) * 0.003,
    y: 0.2 + (index % 15) * 0.003,
    z: -0.01,
  }));
}

function subject(pose, faceX = 0.5, faceY = 0.2) {
  return {
    locked: true,
    visible: true,
    faceX,
    faceY,
    landmarks: pose,
  };
}

test('covered shoulders follow visible torso motion during a short gap', async () => {
  const api = await persistenceModule();
  const tracker = new api.LandmarkPersistence();
  const first = poseFrame();
  tracker.stabilizePose(first, 1000);

  const moved = poseFrame({offsetX: 0.02, shoulders: false});
  const persisted = tracker.stabilizePose(moved, 1100);

  assert.equal(persisted.length, 33);
  assert.ok(Math.abs(persisted[11].x - 0.42) < 1e-9);
  assert.ok(Math.abs(persisted[12].x - 0.62) < 1e-9);
  assert.ok(persisted[11].visibility >= 0.35);
  assert.equal(
    persisted[11][api.PERSISTENCE_CONFIDENCE_KEY],
    persisted[11].visibility,
  );
});

test('pose anchors expire instead of becoming permanent fabricated points', async () => {
  const api = await persistenceModule();
  const tracker = new api.LandmarkPersistence();
  tracker.stabilizePose(poseFrame(), 1000);

  const expired = tracker.stabilizePose([], 1900);

  assert.equal(expired[0], undefined);
  assert.equal(expired[11], undefined);
  assert.equal(expired[12], undefined);
});

test('face mesh follows the locked head through a brief hand occlusion', async () => {
  const api = await persistenceModule();
  const tracker = new api.LandmarkPersistence();
  const pose = poseFrame();
  const face = faceFrame();
  tracker.stabilizeFace(face, subject(pose), 1000);

  const persisted = tracker.stabilizeFace(
    [],
    subject(poseFrame({offsetX: 0.02}), 0.52),
    1200,
  );

  assert.equal(persisted.length, 468);
  assert.ok(Math.abs(persisted[0].x - (face[0].x + 0.02)) < 1e-9);
  assert.ok(persisted[0][api.PERSISTENCE_CONFIDENCE_KEY] < 0.72);
  assert.ok(persisted[0][api.PERSISTENCE_CONFIDENCE_KEY] >= 0.35);
});

test('persisted face mesh scales as the locked signer moves closer', async () => {
  const api = await persistenceModule();
  const tracker = new api.LandmarkPersistence();
  const face = faceFrame();
  tracker.stabilizeFace(face, subject(poseFrame()), 1000);

  const closer = tracker.stabilizeFace(
    [],
    subject(poseFrame({shoulderHalfWidth: 0.118})),
    1100,
  );
  const originalWidth = Math.max(...face.map((point) => point.x)) -
    Math.min(...face.map((point) => point.x));
  const closerWidth = Math.max(...closer.map((point) => point.x)) -
    Math.min(...closer.map((point) => point.x));

  assert.ok(Math.abs(closerWidth / originalWidth - 1.18) < 1e-9);
});

test('face persistence expires and reset clears every cached point', async () => {
  const api = await persistenceModule();
  const tracker = new api.LandmarkPersistence();
  const pose = poseFrame();
  tracker.stabilizeFace(faceFrame(), subject(pose), 1000);

  assert.equal(tracker.stabilizeFace([], subject(pose), 1850).length, 0);

  tracker.stabilizeFace(faceFrame(), subject(pose), 2000);
  tracker.reset();
  assert.equal(tracker.stabilizeFace([], subject(pose), 2100).length, 0);
});

test('the browser tracker parses with the persistence integration', () => {
  assert.doesNotThrow(
    () => new vm.SourceTextModule(trackerSource, {context: vm.createContext({})}),
  );
  assert.match(
    trackerSource,
    /ingestAslFrame\(\{\s*timestampMs,\s*holisticResults: classifierHolisticResults/,
  );
  assert.match(trackerSource, /\.\.\.holisticResults/);
});
