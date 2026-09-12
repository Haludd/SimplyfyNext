"""WebSocket transport for live MediaPipe landmark worlds."""

from __future__ import annotations

import json
import threading
from typing import Any

from websockets.exceptions import ConnectionClosed
from websockets.sync.server import serve

from .models import (
    PayloadValidationError,
    validate_tracking_chunk,
    validate_tracking_frame,
)


# A live utterance is streamed in bounded chunks, so the server does not keep
# the frames in memory. Do not cap the running counter for chunk transport;
# otherwise continuous capture stops being acknowledged after ~25 seconds at
# 24 FPS. Individual legacy ``frame`` messages remain capped below.
MAX_LEGACY_FRAMES_PER_CONNECTION = 600


def _json_bytes(value: dict[str, Any]) -> str:
    return json.dumps(value, separators=(",", ":"))


def _coordinate_summary(frame: dict[str, Any]) -> str:
    worlds = frame.get("landmark_worlds") or {}
    left_hand = worlds.get("left_hand") or {}
    right_hand = worlds.get("right_hand") or {}
    pose = worlds.get("pose") or {}
    face = worlds.get("face") or {}
    left_landmarks = left_hand.get("landmarks", [])
    right_landmarks = right_hand.get("landmarks", [])
    pose_landmarks = pose.get("landmarks", [])
    upper_face = face.get("upper", [])
    mouth = face.get("mouth", [])

    # Keep compatibility with older clients that only sent the flat fields.
    hands = frame.get("hands", [])
    if not worlds:
        left_landmarks = []
        right_landmarks = []
        for hand in hands:
            if not isinstance(hand, dict):
                continue
            if str(hand.get("handedness", "")).lower() == "left":
                left_landmarks = hand.get("landmarks", [])
            elif str(hand.get("handedness", "")).lower() == "right":
                right_landmarks = hand.get("landmarks", [])
        pose_landmarks = [
            point
            for name in ("left_shoulder", "right_shoulder")
            if (point := frame.get(name)) is not None
        ]

    wrist = None
    for landmarks in (left_landmarks, right_landmarks):
        if landmarks and isinstance(landmarks[0], dict):
            wrist = landmarks[0]
            break
    wrist_text = "n/a"
    if wrist is not None:
        wrist_text = "({:.3f}, {:.3f}, {:.3f})".format(
            float(wrist.get("x", 0)),
            float(wrist.get("y", 0)),
            float(wrist.get("z", 0)),
        )
    subject = frame.get("subject_tracking") or {}
    subject_text = "locked" if subject.get("locked") else "searching"
    return (
        f"left_hand={len(left_landmarks)} "
        f"right_hand={len(right_landmarks)} "
        f"pose={len(pose_landmarks)} "
        f"face_upper={len(upper_face)} "
        f"face_mouth={len(mouth)} "
        f"subject={subject_text} "
        f"wrist={wrist_text}"
    )


class LiveTrackingWebSocket:
    """Small threaded WebSocket server used beside the HTTP API.

    The browser sends a ``start`` message, an ``utterance_start`` message, and
    one-second ``chunk`` messages containing several four-world frames. Each
    chunk is validated using the same coordinate contract as the batch HTTP
    endpoint and acknowledged with its running frame/chunk counts. Chunks can
    continue until ``utterance_end`` so the camera can capture continuously.
    Individual ``frame`` messages remain accepted for older clients.
    """

    def __init__(self, host: str = "127.0.0.1", port: int = 8001) -> None:
        self.host = host
        self.port = port
        self._server: Any = None
        self._thread: threading.Thread | None = None
        self._ready = threading.Event()
        self._startup_error: BaseException | None = None
        self._bound_port = port

    @property
    def bound_port(self) -> int:
        """Return the actual listening port, including when ``port`` is 0."""
        return self._bound_port

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(
            target=self._serve,
            name="signbridge-tracking-websocket",
            daemon=True,
        )
        self._thread.start()
        if not self._ready.wait(timeout=5):
            raise RuntimeError("WebSocket server did not start in time")
        if self._startup_error is not None:
            raise RuntimeError("WebSocket server could not start") from self._startup_error

    def _serve(self) -> None:
        try:
            with serve(
                self._handle_connection,
                self.host,
                self.port,
                max_size=1_000_000,
                compression=None,
            ) as server:
                self._server = server
                socket = getattr(server, "socket", None)
                if socket is not None:
                    self._bound_port = int(socket.getsockname()[1])
                self._ready.set()
                server.serve_forever()
        except BaseException as error:
            self._startup_error = error
            self._ready.set()

    def _handle_connection(self, connection: Any) -> None:
        session_id: str | None = None
        utterance_id: str | None = None
        frames_received = 0
        chunks_received = 0
        try:
            connection.send(
                _json_bytes(
                    {
                        "type": "ready",
                        "protocol": "signbridge-tracking-v1",
                    }
                )
            )
            for raw_message in connection:
                try:
                    message = json.loads(raw_message)
                    if not isinstance(message, dict):
                        raise PayloadValidationError("message must be a JSON object")
                    message_type = message.get("type")

                    if message_type == "start":
                        value = message.get("session_id")
                        if not isinstance(value, str) or not value.strip():
                            raise PayloadValidationError(
                                "start.session_id must be a non-empty string"
                            )
                        session_id = value.strip()
                        frames_received = 0
                        utterance_id = None
                        chunks_received = 0
                        connection.send(
                            _json_bytes(
                                {
                                    "type": "started",
                                    "session_id": session_id,
                                }
                            )
                        )
                        continue

                    if message_type == "utterance_start":
                        if session_id is None:
                            raise PayloadValidationError(
                                "send start before starting an utterance"
                            )
                        value = message.get("utterance_id")
                        if not isinstance(value, str) or not value.strip():
                            raise PayloadValidationError(
                                "utterance_start.utterance_id must be a non-empty string"
                            )
                        utterance_id = value.strip()
                        frames_received = 0
                        chunks_received = 0
                        connection.send(
                            _json_bytes(
                                {
                                    "type": "utterance_started",
                                    "session_id": session_id,
                                    "utterance_id": utterance_id,
                                }
                            )
                        )
                        continue

                    if message_type == "chunk":
                        if session_id is None:
                            raise PayloadValidationError(
                                "send start before sending chunks"
                            )
                        if utterance_id is None:
                            raise PayloadValidationError(
                                "send utterance_start before sending chunks"
                            )
                        if message.get("session_id") != session_id:
                            raise PayloadValidationError(
                                "chunk.session_id does not match the active session"
                            )
                        if message.get("utterance_id") != utterance_id:
                            raise PayloadValidationError(
                                "chunk.utterance_id does not match the active utterance"
                            )
                        validate_tracking_chunk(message)
                        chunk_frames = message["frames"]
                        frames_received += len(chunk_frames)
                        chunks_received += 1
                        safe_session_id = session_id.replace("\n", " ")[:80]
                        safe_utterance_id = utterance_id.replace("\n", " ")[:80]
                        features = message.get("features", {})
                        latest_frame = chunk_frames[-1]
                        print(
                            f"[tracking] session={safe_session_id} "
                            f"utterance={safe_utterance_id} "
                            f"chunk={message['chunk_id']} "
                            f"chunk_frames={len(chunk_frames)} "
                            f"total_frames={frames_received} "
                            f"avg_velocity={float(features.get('average_velocity', 0)):.3f} "
                            f"peak_velocity={float(features.get('peak_velocity', 0)):.3f} "
                            f"avg_acceleration={float(features.get('average_acceleration', 0)):.3f} "
                            f"{_coordinate_summary(latest_frame)}",
                            flush=True,
                        )
                        connection.send(
                            _json_bytes(
                                {
                                    "type": "chunk_ack",
                                    "session_id": session_id,
                                    "utterance_id": utterance_id,
                                    "chunk_id": message["chunk_id"],
                                    "chunks_received": chunks_received,
                                    "frames_received": frames_received,
                                }
                            )
                        )
                        continue

                    if message_type == "utterance_end":
                        if session_id is None:
                            raise PayloadValidationError(
                                "send start before ending an utterance"
                            )
                        if utterance_id is not None and message.get("utterance_id") != utterance_id:
                            raise PayloadValidationError(
                                "utterance_end.utterance_id does not match the active utterance"
                            )
                        connection.send(
                            _json_bytes(
                                {
                                    "type": "utterance_ended",
                                    "session_id": session_id,
                                    "utterance_id": utterance_id,
                                    "chunks_received": chunks_received,
                                    "frames_received": frames_received,
                                }
                            )
                        )
                        utterance_id = None
                        frames_received = 0
                        chunks_received = 0
                        continue

                    if message_type == "frame":
                        if session_id is None:
                            raise PayloadValidationError(
                                "send start before sending frames"
                            )
                        frame = message.get("frame")
                        validate_tracking_frame(frame)
                        frames_received += 1
                        if frames_received > MAX_LEGACY_FRAMES_PER_CONNECTION:
                            raise PayloadValidationError(
                                "a legacy frame connection cannot send more than "
                                f"{MAX_LEGACY_FRAMES_PER_CONNECTION} frames"
                            )
                        if frames_received == 1 or frames_received % 10 == 0:
                            safe_session_id = session_id.replace("\n", " ")[:80]
                            print(
                                f"[tracking] session={safe_session_id} "
                                f"frames_received={frames_received} "
                                f"{_coordinate_summary(frame)}",
                                flush=True,
                            )
                        connection.send(
                            _json_bytes(
                                {
                                    "type": "frame_ack",
                                    "session_id": session_id,
                                    "frames_received": frames_received,
                                }
                            )
                        )
                        continue

                    if message_type == "end":
                        connection.send(
                            _json_bytes(
                                {
                                    "type": "ended",
                                    "session_id": session_id,
                                    "frames_received": frames_received,
                                }
                            )
                        )
                        return

                    raise PayloadValidationError(
                        "message.type must be start, frame, or end"
                    )
                except (json.JSONDecodeError, PayloadValidationError) as error:
                    connection.send(
                        _json_bytes(
                            {
                                "type": "error",
                                "error": "invalid_tracking_message",
                                "detail": str(error),
                            }
                        )
                    )
        except (ConnectionClosed, OSError):
            # A browser closing its camera tab is a normal disconnect.
            return

    def stop(self) -> None:
        server = self._server
        if server is not None:
            server.shutdown()
        if self._thread is not None:
            self._thread.join(timeout=5)
