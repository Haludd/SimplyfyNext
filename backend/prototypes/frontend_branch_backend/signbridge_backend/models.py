"""Validation and typed access for the Flutter sign-sequence contract."""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Any


class PayloadValidationError(ValueError):
    """Raised when a client sends a malformed or unsafe sequence payload."""


def _required_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PayloadValidationError(f"{field} must be a non-empty string")
    return value.strip()


def _required_list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise PayloadValidationError(f"{field} must be a list")
    return value


def _finite_number(value: Any, field: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise PayloadValidationError(f"{field} must be a number")
    result = float(value)
    if not math.isfinite(result):
        raise PayloadValidationError(f"{field} must be finite")
    return result


def _validate_landmarks(frame_index: int, hand_index: int, hand: dict[str, Any]) -> None:
    landmarks = _required_list(
        hand.get("landmarks", []),
        f"frames[{frame_index}].hands[{hand_index}].landmarks",
    )
    if len(landmarks) not in (0, 21):
        raise PayloadValidationError(
            f"frames[{frame_index}].hands[{hand_index}].landmarks must contain 21 points"
        )
    for point_index, point in enumerate(landmarks):
        if not isinstance(point, dict):
            raise PayloadValidationError(
                f"frames[{frame_index}].hands[{hand_index}].landmarks[{point_index}] must be an object"
            )
        for axis in ("x", "y", "z"):
            _finite_number(
                point.get(axis),
                f"frames[{frame_index}].hands[{hand_index}].landmarks[{point_index}].{axis}",
            )
        for axis in ("world_x", "world_y", "world_z"):
            if axis in point and point[axis] is not None:
                _finite_number(
                    point[axis],
                    f"frames[{frame_index}].hands[{hand_index}].landmarks[{point_index}].{axis}",
                )


def _validate_world_point(point: Any, field: str) -> None:
    if not isinstance(point, dict):
        raise PayloadValidationError(f"{field} must be an object")
    if "index" in point:
        index = point["index"]
        if not isinstance(index, int) or isinstance(index, bool) or index < 0:
            raise PayloadValidationError(f"{field}.index must be a non-negative integer")
    if "name" in point and point["name"] is not None:
        _required_string(point["name"], f"{field}.name")
    for axis in ("x", "y", "z"):
        _finite_number(point.get(axis), f"{field}.{axis}")
    for axis in ("world_x", "world_y", "world_z", "visibility", "presence"):
        if axis in point and point[axis] is not None:
            _finite_number(point[axis], f"{field}.{axis}")


def _validate_world_hand(
    frame_index: int,
    side: str,
    world: Any,
) -> None:
    field = f"frames[{frame_index}].landmark_worlds.{side}_hand"
    if not isinstance(world, dict):
        raise PayloadValidationError(f"{field} must be an object")
    handedness = _required_string(world.get("handedness"), f"{field}.handedness").lower()
    if handedness != side:
        raise PayloadValidationError(f"{field}.handedness must be '{side}'")
    _finite_number(world.get("confidence", 0), f"{field}.confidence")
    landmarks = _required_list(world.get("landmarks", []), f"{field}.landmarks")
    if len(landmarks) not in (0, 21):
        raise PayloadValidationError(f"{field}.landmarks must contain 21 points")
    for point_index, point in enumerate(landmarks):
        _validate_world_point(point, f"{field}.landmarks[{point_index}]")


def _validate_world_landmarks(
    frame_index: int,
    world: Any,
    group: str,
    limit: int,
) -> None:
    field = f"frames[{frame_index}].landmark_worlds.{group}"
    if not isinstance(world, dict):
        raise PayloadValidationError(f"{field} must be an object")
    landmarks = _required_list(world.get("landmarks", []), f"{field}.landmarks")
    if len(landmarks) > limit:
        raise PayloadValidationError(
            f"{field}.landmarks cannot contain more than {limit} points"
        )
    for point_index, point in enumerate(landmarks):
        _validate_world_point(point, f"{field}.landmarks[{point_index}]")


def _validate_landmark_worlds(frame_index: int, frame: dict[str, Any]) -> None:
    """Validate the four-world representation emitted by the web tracker."""
    worlds = frame.get("landmark_worlds")
    if worlds is None:
        return
    if not isinstance(worlds, dict):
        raise PayloadValidationError(f"frames[{frame_index}].landmark_worlds must be an object")

    required_worlds = ("left_hand", "right_hand", "pose", "face")
    missing = [name for name in required_worlds if name not in worlds]
    if missing:
        raise PayloadValidationError(
            f"frames[{frame_index}].landmark_worlds is missing: {', '.join(missing)}"
        )
    _validate_world_hand(frame_index, "left", worlds["left_hand"])
    _validate_world_hand(frame_index, "right", worlds["right_hand"])
    _validate_world_landmarks(frame_index, worlds["pose"], "pose", 33)

    face_field = f"frames[{frame_index}].landmark_worlds.face"
    face = worlds["face"]
    if not isinstance(face, dict):
        raise PayloadValidationError(f"{face_field} must be an object")
    for group in ("upper", "mouth"):
        group_field = f"frames[{frame_index}].landmark_worlds.face.{group}"
        landmarks = _required_list(face.get(group, []), group_field)
        if len(landmarks) > 468:
            raise PayloadValidationError(
                f"{group_field} cannot contain more than 468 points"
            )
        for point_index, point in enumerate(landmarks):
            _validate_world_point(point, f"{group_field}[{point_index}]")


def _validate_motion(frame_index: int, frame: dict[str, Any]) -> None:
    motion = frame.get("hand_motion")
    if motion is None:
        return
    field = f"frames[{frame_index}].hand_motion"
    if not isinstance(motion, dict):
        raise PayloadValidationError(f"{field} must be an object")
    for name in (
        "average_speed",
        "average_velocity",
        "peak_velocity",
        "average_acceleration",
        "peak_acceleration",
    ):
        if name in motion and motion[name] is not None:
            _finite_number(motion[name], f"{field}.{name}")
    if "direction" in motion and motion["direction"] is not None:
        _required_string(motion["direction"], f"{field}.direction")
    per_hand = motion.get("per_hand")
    if per_hand is not None:
        if not isinstance(per_hand, dict):
            raise PayloadValidationError(f"{field}.per_hand must be an object")
        for side in ("left", "right"):
            values = per_hand.get(side)
            if values is None:
                continue
            if not isinstance(values, dict):
                raise PayloadValidationError(f"{field}.per_hand.{side} must be an object")
            for name in ("velocity", "acceleration"):
                if name in values and values[name] is not None:
                    _finite_number(values[name], f"{field}.per_hand.{side}.{name}")


def _validate_subject_tracking(frame_index: int, frame: dict[str, Any]) -> None:
    subject = frame.get("subject_tracking")
    if subject is None:
        return
    field = f"frames[{frame_index}].subject_tracking"
    if not isinstance(subject, dict):
        raise PayloadValidationError(f"{field} must be an object")
    if "locked" in subject and not isinstance(subject["locked"], bool):
        raise PayloadValidationError(f"{field}.locked must be a boolean")
    for name in ("center_x", "center_y", "area"):
        if name in subject and subject[name] is not None:
            _finite_number(subject[name], f"{field}.{name}")
    if "missing_frames" in subject:
        missing_frames = subject["missing_frames"]
        if (
            not isinstance(missing_frames, int)
            or isinstance(missing_frames, bool)
            or missing_frames < 0
        ):
            raise PayloadValidationError(
                f"{field}.missing_frames must be a non-negative integer"
            )


def _validate_frame(index: int, frame: Any) -> None:
    if not isinstance(frame, dict):
        raise PayloadValidationError(f"frames[{index}] must be an object")
    _required_string(frame.get("timestamp"), f"frames[{index}].timestamp")
    confidence = frame.get("tracking_confidence", 0)
    _finite_number(confidence, f"frames[{index}].tracking_confidence")

    hands = _required_list(frame.get("hands", []), f"frames[{index}].hands")
    if len(hands) > 2:
        raise PayloadValidationError(f"frames[{index}].hands cannot contain more than 2 hands")
    for hand_index, hand in enumerate(hands):
        if not isinstance(hand, dict):
            raise PayloadValidationError(f"frames[{index}].hands[{hand_index}] must be an object")
        _required_string(hand.get("handedness", "unknown"), f"frames[{index}].hands[{hand_index}].handedness")
        _finite_number(hand.get("confidence", 0), f"frames[{index}].hands[{hand_index}].confidence")
        _validate_landmarks(index, hand_index, hand)

    face = frame.get("face_expression")
    if face is not None:
        if not isinstance(face, dict):
            raise PayloadValidationError(f"frames[{index}].face_expression must be an object")
        if "confidence" in face:
            _finite_number(face["confidence"], f"frames[{index}].face_expression.confidence")
        if "label" in face and face["label"] is not None:
            _required_string(face["label"], f"frames[{index}].face_expression.label")

    _validate_landmark_worlds(index, frame)
    _validate_motion(index, frame)
    _validate_subject_tracking(index, frame)


def validate_tracking_frame(frame: Any) -> None:
    """Validate one live frame received through the WebSocket transport."""
    _validate_frame(0, frame)


def validate_tracking_chunk(chunk: Any) -> None:
    """Validate one utterance chunk received through the WebSocket."""
    if not isinstance(chunk, dict):
        raise PayloadValidationError("chunk must be an object")
    for field in ("utterance_id", "chunk_id", "started_at", "ended_at"):
        _required_string(chunk.get(field), f"chunk.{field}")
    frames = _required_list(chunk.get("frames"), "chunk.frames")
    if not frames:
        raise PayloadValidationError("chunk.frames must contain at least one frame")
    if len(frames) > 600:
        raise PayloadValidationError("chunk.frames cannot contain more than 600 frames")
    frame_count = chunk.get("frame_count")
    if not isinstance(frame_count, int) or isinstance(frame_count, bool):
        raise PayloadValidationError("chunk.frame_count must be an integer")
    if frame_count != len(frames):
        raise PayloadValidationError("chunk.frame_count must equal the number of frames")
    for index, frame in enumerate(frames):
        _validate_frame(index, frame)

    features = chunk.get("features", {})
    if not isinstance(features, dict):
        raise PayloadValidationError("chunk.features must be an object")
    for name in (
        "average_velocity",
        "peak_velocity",
        "average_acceleration",
        "peak_acceleration",
    ):
        if name in features and features[name] is not None:
            _finite_number(features[name], f"chunk.features.{name}")
    if "direction" in features and features["direction"] is not None:
        _required_string(features["direction"], "chunk.features.direction")


@dataclass(frozen=True)
class SignSequencePayload:
    """Validated representation of the JSON emitted by the Flutter client."""

    session_id: str
    sequence_id: str
    language: str
    started_at: str
    ended_at: str
    frame_count: int
    lexicon_version: str
    frames: list[dict[str, Any]]

    @classmethod
    def from_dict(cls, value: Any) -> "SignSequencePayload":
        if not isinstance(value, dict):
            raise PayloadValidationError("request body must be a JSON object")

        session_id = _required_string(value.get("session_id"), "session_id")
        sequence_id = _required_string(value.get("sequence_id"), "sequence_id")
        language = _required_string(value.get("language"), "language").upper()
        started_at = _required_string(value.get("started_at"), "started_at")
        ended_at = _required_string(value.get("ended_at"), "ended_at")
        lexicon_version = _required_string(value.get("lexicon_version"), "lexicon_version")
        frames = _required_list(value.get("frames"), "frames")
        if not frames:
            raise PayloadValidationError("frames must contain at least one frame")
        if len(frames) > 600:
            raise PayloadValidationError("frames cannot contain more than 600 frames")
        for index, frame in enumerate(frames):
            _validate_frame(index, frame)

        frame_count = value.get("frame_count")
        if not isinstance(frame_count, int) or isinstance(frame_count, bool):
            raise PayloadValidationError("frame_count must be an integer")
        if frame_count != len(frames):
            raise PayloadValidationError("frame_count must equal the number of frames")

        return cls(
            session_id=session_id,
            sequence_id=sequence_id,
            language=language,
            started_at=started_at,
            ended_at=ended_at,
            frame_count=frame_count,
            lexicon_version=lexicon_version,
            frames=frames,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "sequence_id": self.sequence_id,
            "language": self.language,
            "started_at": self.started_at,
            "ended_at": self.ended_at,
            "frame_count": self.frame_count,
            "lexicon_version": self.lexicon_version,
            "frames": self.frames,
        }
