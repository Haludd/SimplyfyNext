const DEFAULT_POSE_ANCHORS = [0, 11, 12];
const DEFAULT_POSE_REFERENCES = [0, 11, 12, 23, 24];
const DEFAULT_OBSERVATION_CONFIDENCE = 0.35;
const DEFAULT_PERSISTED_CONFIDENCE_FLOOR = 0.36;
const DEFAULT_POSE_OCCLUSION_HOLD_MS = 1400;
const DEFAULT_FACE_OCCLUSION_HOLD_MS = 1600;
const PERSISTENCE_CONFIDENCE_KEY = '__signbridgePersistenceConfidence';

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, Number(value) || 0));
}

function finitePoint(point) {
  return Boolean(
    point &&
      Number.isFinite(point.x) &&
      Number.isFinite(point.y) &&
      Number.isFinite(point.z ?? 0),
  );
}

function pointConfidence(point) {
  return clamp(point?.visibility ?? point?.presence ?? 0, 0, 1);
}

function clonePoint(point) {
  return {
    ...point,
    x: Number(point.x),
    y: Number(point.y),
    z: Number(point.z ?? 0),
  };
}

function meanPoint(points) {
  if (!points.length) return null;
  return {
    x: points.reduce((sum, point) => sum + point.x, 0) / points.length,
    y: points.reduce((sum, point) => sum + point.y, 0) / points.length,
  };
}

function pointBounds(points) {
  const finite = points.filter(finitePoint);
  if (!finite.length) return null;
  const xs = finite.map((point) => point.x);
  const ys = finite.map((point) => point.y);
  return {
    minX: Math.min(...xs),
    maxX: Math.max(...xs),
    minY: Math.min(...ys),
    maxY: Math.max(...ys),
  };
}

function nearestFaceCandidate(candidates, targetX, targetY) {
  return candidates.reduce((best, candidate) => {
    const points = Array.isArray(candidate)
      ? candidate.filter(finitePoint)
      : [];
    if (!points.length) return best;
    const centre = meanPoint(points);
    const distance = Math.hypot(centre.x - targetX, centre.y - targetY);
    return !best || distance < best.distance ? {points, distance} : best;
  }, null);
}

/**
 * Selects a real face mesh for the locked signer. A pose detector can briefly
 * disappear when the signer moves close to the camera, while Face Mesh still
 * has a valid result. The existing lock is therefore allowed to reacquire a
 * nearby face without promoting a different person to the session.
 */
export function selectLockedFace(
  candidates,
  subject,
  {matchDistance = 0.25, reacquireDistance = 0.34} = {},
) {
  if (!subject?.locked || !Array.isArray(candidates) || !candidates.length) {
    return [];
  }
  const targetX = Number.isFinite(subject.faceX) ? subject.faceX : 0.5;
  const targetY = Number.isFinite(subject.faceY) ? subject.faceY : 0.35;
  const nearest = nearestFaceCandidate(candidates, targetX, targetY);
  const maximumDistance = subject.visible === false
    ? reacquireDistance
    : matchDistance;
  return nearest && nearest.distance <= maximumDistance ? nearest.points : [];
}

function shoulderWidth(subject) {
  const left = subject?.landmarks?.[11];
  const right = subject?.landmarks?.[12];
  if (!finitePoint(left) || !finitePoint(right)) return null;
  return Math.hypot(left.x - right.x, left.y - right.y);
}

/**
 * Bridges short MediaPipe pose/face gaps without mutating the raw Holistic
 * result. Callers can copy the bounded output into the local classifier frame;
 * every inferred point loses confidence with age and expires.
 */
export class LandmarkPersistence {
  constructor({
    poseHoldMs = 900,
    faceHoldMs = 1100,
    poseOcclusionHoldMs = DEFAULT_POSE_OCCLUSION_HOLD_MS,
    faceOcclusionHoldMs = DEFAULT_FACE_OCCLUSION_HOLD_MS,
    observationConfidence = DEFAULT_OBSERVATION_CONFIDENCE,
    confidenceFloor = DEFAULT_PERSISTED_CONFIDENCE_FLOOR,
    poseAnchorIndices = DEFAULT_POSE_ANCHORS,
    poseReferenceIndices = DEFAULT_POSE_REFERENCES,
  } = {}) {
    this.poseHoldMs = poseHoldMs;
    this.faceHoldMs = faceHoldMs;
    this.poseOcclusionHoldMs = Math.max(poseHoldMs, poseOcclusionHoldMs);
    this.faceOcclusionHoldMs = Math.max(faceHoldMs, faceOcclusionHoldMs);
    this.observationConfidence = observationConfidence;
    this.confidenceFloor = confidenceFloor;
    this.poseAnchorIndices = [...poseAnchorIndices];
    this.poseReferenceIndices = [...poseReferenceIndices];
    this.reset();
  }

  reset() {
    this.poseAnchors = new Map();
    this.poseReferences = new Map();
    this.lastPoseFrameAt = null;
    this.face = null;
  }

  stabilizePose(landmarks, timestampMs, {occluderLandmarks = []} = {}) {
    const time = Number(timestampMs);
    const input = Array.isArray(landmarks) ? landmarks : [];
    const outputLength = Math.max(
      input.length,
      this.poseAnchors.size > 0 ? 33 : 0,
    );
    const output = Array.from(
      {length: outputLength},
      (_, index) => input[index],
    );
    const elapsedSeconds = this.lastPoseFrameAt == null
      ? 0
      : clamp((time - this.lastPoseFrameAt) / 1000, 0, 0.1);
    const bodyMotion = this.#bodyMotion(input);

    for (const index of this.poseAnchorIndices) {
      const measured = input[index];
      const previous = this.poseAnchors.get(index);
      if (
        finitePoint(measured) &&
        pointConfidence(measured) >= this.observationConfidence
      ) {
        const point = clonePoint(measured);
        let velocity = previous?.velocity ?? {x: 0, y: 0, z: 0};
        if (previous?.observed && time > previous.observedAt) {
          const seconds = clamp(
            (time - previous.observedAt) / 1000,
            1 / 120,
            0.25,
          );
          const measuredVelocity = {
            x: clamp((point.x - previous.observed.x) / seconds, -0.8, 0.8),
            y: clamp((point.y - previous.observed.y) / seconds, -0.8, 0.8),
            z: clamp((point.z - previous.observed.z) / seconds, -0.8, 0.8),
          };
          velocity = {
            x: velocity.x * 0.65 + measuredVelocity.x * 0.35,
            y: velocity.y * 0.65 + measuredVelocity.y * 0.35,
            z: velocity.z * 0.65 + measuredVelocity.z * 0.35,
          };
        }
        this.poseAnchors.set(index, {
          observed: point,
          observedAt: time,
          output: point,
          velocity,
        });
        output[index] = point;
        continue;
      }

      if (!previous) continue;
      const ageMs = time - previous.observedAt;
      const occluded = this.#pointHasNearbyOccluder(
        previous.output,
        occluderLandmarks,
        0.13,
      );
      const holdMs = occluded ? this.poseOcclusionHoldMs : this.poseHoldMs;
      if (!Number.isFinite(ageMs) || ageMs < 0 || ageMs >= holdMs) {
        this.poseAnchors.delete(index);
        continue;
      }

      const motion = bodyMotion.count > 0
        ? bodyMotion
        : {
            x: previous.velocity.x * elapsedSeconds,
            y: previous.velocity.y * elapsedSeconds,
            z: previous.velocity.z * elapsedSeconds,
          };
      const visibility = this.#decayedConfidence(
        pointConfidence(previous.observed),
        ageMs,
        holdMs,
        0.72,
      );
      const point = {
        ...previous.output,
        x: clamp(previous.output.x + clamp(motion.x, -0.06, 0.06), 0, 1),
        y: clamp(previous.output.y + clamp(motion.y, -0.06, 0.06), 0, 1),
        z: previous.output.z + clamp(motion.z, -0.06, 0.06),
        visibility,
        presence: visibility,
        [PERSISTENCE_CONFIDENCE_KEY]: visibility,
      };
      previous.output = point;
      output[index] = point;
    }

    this.lastPoseFrameAt = time;
    return output;
  }

  stabilizeFace(
    landmarks,
    subject,
    timestampMs,
    {occluderLandmarks = []} = {},
  ) {
    const time = Number(timestampMs);
    const input = Array.isArray(landmarks) ? landmarks : [];
    const observed = input.filter(finitePoint);
    if (observed.length >= 468) {
      const points = input.map((point) =>
        finitePoint(point) ? clonePoint(point) : point,
      );
      const centre = meanPoint(observed);
      this.face = {
        points,
        observedAt: time,
        centre,
        bounds: pointBounds(observed),
        subjectX: Number.isFinite(subject?.faceX) ? subject.faceX : centre.x,
        subjectY: Number.isFinite(subject?.faceY) ? subject.faceY : centre.y,
        shoulderWidth: shoulderWidth(subject),
      };
      return points;
    }

    const cached = this.face;
    const ageMs = cached ? time - cached.observedAt : Number.POSITIVE_INFINITY;
    const occluded = cached && this.#faceHasNearbyOccluder(
      cached.bounds,
      occluderLandmarks,
    );
    const holdMs = occluded ? this.faceOcclusionHoldMs : this.faceHoldMs;
    if (
      !cached ||
      !subject?.locked ||
      !Number.isFinite(ageMs) ||
      ageMs < 0 ||
      ageMs >= holdMs
    ) {
      if (ageMs >= holdMs) this.face = null;
      return [];
    }

    const currentX = Number.isFinite(subject.faceX)
      ? subject.faceX
      : cached.subjectX;
    const currentY = Number.isFinite(subject.faceY)
      ? subject.faceY
      : cached.subjectY;
    const currentWidth = shoulderWidth(subject);
    const scale = currentWidth && cached.shoulderWidth
      ? clamp(currentWidth / cached.shoulderWidth, 0.85, 1.18)
      : 1;
    const shiftX = clamp(currentX - cached.subjectX, -0.16, 0.16);
    const shiftY = clamp(currentY - cached.subjectY, -0.16, 0.16);
    const visibility = this.#decayedConfidence(
      0.72,
      ageMs,
      holdMs,
      0.72,
    );

    return cached.points.map((point) => {
      if (!finitePoint(point)) return point;
      return {
        ...point,
        x: clamp(
          cached.centre.x + (point.x - cached.centre.x) * scale + shiftX,
          0,
          1,
        ),
        y: clamp(
          cached.centre.y + (point.y - cached.centre.y) * scale + shiftY,
          0,
          1,
        ),
        z: point.z * scale,
        [PERSISTENCE_CONFIDENCE_KEY]: visibility,
      };
    });
  }

  #bodyMotion(landmarks) {
    const deltas = [];
    for (const index of this.poseReferenceIndices) {
      const point = landmarks[index];
      if (
        !finitePoint(point) ||
        pointConfidence(point) < this.observationConfidence
      ) {
        continue;
      }
      const current = clonePoint(point);
      const previous = this.poseReferences.get(index);
      if (previous) {
        deltas.push({
          x: current.x - previous.x,
          y: current.y - previous.y,
          z: current.z - previous.z,
        });
      }
      this.poseReferences.set(index, current);
    }
    if (!deltas.length) return {x: 0, y: 0, z: 0, count: 0};
    return {
      x: deltas.reduce((sum, delta) => sum + delta.x, 0) / deltas.length,
      y: deltas.reduce((sum, delta) => sum + delta.y, 0) / deltas.length,
      z: deltas.reduce((sum, delta) => sum + delta.z, 0) / deltas.length,
      count: deltas.length,
    };
  }

  #pointHasNearbyOccluder(point, occluders, radius) {
    if (!finitePoint(point) || !Array.isArray(occluders)) return false;
    return occluders.some((occluder) =>
      finitePoint(occluder) &&
      Math.hypot(occluder.x - point.x, occluder.y - point.y) <= radius,
    );
  }

  #faceHasNearbyOccluder(bounds, occluders) {
    if (!bounds || !Array.isArray(occluders)) return false;
    const width = Math.max(0.01, bounds.maxX - bounds.minX);
    const height = Math.max(0.01, bounds.maxY - bounds.minY);
    const paddingX = Math.max(0.06, width * 0.28);
    const paddingY = Math.max(0.06, height * 0.22);
    return occluders.some((point) =>
      finitePoint(point) &&
      point.x >= bounds.minX - paddingX &&
      point.x <= bounds.maxX + paddingX &&
      point.y >= bounds.minY - paddingY &&
      point.y <= bounds.maxY + paddingY,
    );
  }

  #decayedConfidence(observed, ageMs, holdMs, ceiling) {
    const start = clamp(
      observed,
      this.confidenceFloor + 0.01,
      ceiling,
    );
    const progress = clamp(ageMs / holdMs, 0, 1);
    return start + (this.confidenceFloor - start) * progress;
  }
}

export {PERSISTENCE_CONFIDENCE_KEY};
