"""Replaceable baseline analyzer for hand, motion, and face features."""

from __future__ import annotations

import math
from datetime import datetime
from typing import Any

from .models import SignSequencePayload


class SignAnalyzer:
    """A safe closed-vocabulary baseline until a trained model is available.

    This intentionally returns a candidate handshape instead of pretending that
    a few geometric thresholds are a complete ASL translator. A trained
    sequence model can implement the same ``analyze`` method later.
    """

    def __init__(self, model_version: str = "heuristic-signbridge-v1") -> None:
        self.model_version = model_version

    def analyze(self, payload: SignSequencePayload) -> dict[str, Any]:
        tracked_frames = [
            frame for frame in payload.frames if frame.get("hands")
        ]
        if not tracked_frames:
            return {
                "status": "no_signal",
                "gesture_label": "No hand signal",
                "caption": "Show your hands to begin tracking.",
                "confidence": 0.0,
                "gloss_trace": [],
                "detail": "No hand landmarks were present in the sequence.",
                "chunk_summary": self._motion_summary(payload.frames),
                "model_version": self.model_version,
                "language": payload.language,
            }

        latest = tracked_frames[-1]
        hands = latest.get("hands", [])
        openness_values = [self._hand_openness(hand) for hand in hands]
        openness_values = [value for value in openness_values if value is not None]
        motion = latest.get("hand_motion") or {}
        openness = (
            sum(openness_values) / len(openness_values)
            if openness_values
            else float(motion.get("average_openness", 0.0) or 0.0)
        )
        speed = float(motion.get("average_speed", 0.0) or 0.0)
        label = self._gesture_label(openness)
        tracking_confidence = float(latest.get("tracking_confidence", 0.0) or 0.0)
        confidence = max(0.0, min(0.99, tracking_confidence * 0.65 + (0.35 if openness > 0.1 else 0.12)))
        face = latest.get("face_expression") or {}
        face_label = str(face.get("label", "not detected"))
        motion_summary = self._motion_summary(payload.frames)
        worlds = latest.get("landmark_worlds") or {}
        left_world = worlds.get("left_hand") or {}
        right_world = worlds.get("right_hand") or {}
        pose_world = worlds.get("pose") or {}
        face_world = worlds.get("face") or {}

        return {
            "status": "candidate",
            "gesture_label": label,
            "caption": "Hand sequence captured — review candidate before translation.",
            "confidence": round(confidence, 4),
            "gloss_trace": [label.upper()],
            "chunk_summary": motion_summary,
            "detail": (
                f"{len(tracked_frames)} frames · {len(hands)} hand(s) · "
                f"{speed:.2f} motion · face {face_label} · "
                f"velocity {motion_summary['average_velocity']:.3f} "
                f"(peak {motion_summary['peak_velocity']:.3f}) · "
                f"acceleration {motion_summary['average_acceleration']:.3f} · "
                f"worlds L{len(left_world.get('landmarks', []))}/"
                f"R{len(right_world.get('landmarks', []))}/"
                f"P{len(pose_world.get('landmarks', []))}/"
                f"F{len(face_world.get('upper', [])) + len(face_world.get('mouth', []))} · "
                "heuristic baseline, not a trained ASL translation model."
            ),
            "model_version": self.model_version,
            "language": payload.language,
        }

    def _motion_summary(self, frames: list[dict[str, Any]]) -> dict[str, Any]:
        motions = [
            frame.get("hand_motion") or {}
            for frame in frames
            if isinstance(frame.get("hand_motion"), dict)
        ]

        def values(name: str, fallback: str | None = None) -> list[float]:
            result: list[float] = []
            for motion in motions:
                value = motion.get(name)
                if value is None and fallback is not None:
                    value = motion.get(fallback)
                if isinstance(value, (int, float)):
                    result.append(float(value))
            return result

        def average(items: list[float]) -> float:
            return sum(items) / len(items) if items else 0.0

        velocities = values("average_velocity", "average_speed")
        peak_velocities = values("peak_velocity", "average_velocity")
        accelerations = values("average_acceleration")
        peak_accelerations = values("peak_acceleration", "average_acceleration")
        directions = [
            str(motion["direction"])
            for motion in motions
            if motion.get("direction")
        ]
        direction_counts = {
            direction: directions.count(direction)
            for direction in sorted(set(directions))
        }
        per_hand: dict[str, dict[str, float]] = {}
        for side in ("left", "right"):
            side_values = [
                motion.get("per_hand", {}).get(side, {})
                for motion in motions
                if isinstance(motion.get("per_hand"), dict)
                and isinstance(motion.get("per_hand", {}).get(side), dict)
            ]
            side_velocities = [
                float(value["velocity"])
                for value in side_values
                if isinstance(value.get("velocity"), (int, float))
            ]
            side_accelerations = [
                float(value["acceleration"])
                for value in side_values
                if isinstance(value.get("acceleration"), (int, float))
            ]
            per_hand[side] = {
                "average_velocity": average(side_velocities),
                "peak_velocity": max(side_velocities, default=0.0),
                "average_acceleration": average(side_accelerations),
                "peak_acceleration": max(side_accelerations, default=0.0),
            }

        duration_ms = 0
        if len(frames) >= 2:
            try:
                started = datetime.fromisoformat(
                    str(frames[0]["timestamp"]).replace("Z", "+00:00")
                )
                ended = datetime.fromisoformat(
                    str(frames[-1]["timestamp"]).replace("Z", "+00:00")
                )
                duration_ms = max(0, int((ended - started).total_seconds() * 1000))
            except (KeyError, TypeError, ValueError):
                duration_ms = 0

        return {
            "frame_count": len(frames),
            "duration_ms": duration_ms,
            "average_velocity": round(average(velocities), 6),
            "peak_velocity": round(max(peak_velocities, default=0.0), 6),
            "average_acceleration": round(average(accelerations), 6),
            "peak_acceleration": round(max(peak_accelerations, default=0.0), 6),
            "direction_counts": direction_counts,
            "per_hand": per_hand,
        }

    def _gesture_label(self, openness: float) -> str:
        if openness >= 0.8:
            return "open hand"
        if openness <= 0.2:
            return "closed hand"
        if 0.35 <= openness <= 0.5:
            return "partial handshape"
        return "unknown handshape"

    def _hand_openness(self, hand: dict[str, Any]) -> float | None:
        landmarks = hand.get("landmarks", [])
        if len(landmarks) < 21:
            return None
        wrist = landmarks[0]
        tips = (4, 8, 12, 16, 20)
        mcps = (2, 5, 9, 13, 17)
        extended = 0
        for tip_index, mcp_index in zip(tips, mcps):
            if self._distance(landmarks[tip_index], wrist) > self._distance(landmarks[mcp_index], wrist) * 1.18:
                extended += 1
        return extended / len(tips)

    @staticmethod
    def _distance(first: dict[str, Any], second: dict[str, Any]) -> float:
        return math.sqrt(
            sum(
                (float(first[axis]) - float(second[axis])) ** 2
                for axis in ("x", "y", "z")
            )
        )
