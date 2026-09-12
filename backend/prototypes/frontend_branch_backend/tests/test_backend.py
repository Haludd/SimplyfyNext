from __future__ import annotations

import tempfile
import json
import threading
from urllib.request import Request, urlopen
import unittest
from pathlib import Path

from backend.signbridge_backend.http_api import create_server
from backend.signbridge_backend.models import PayloadValidationError, SignSequencePayload
from backend.signbridge_backend.service import SignBridgeBackend
from backend.signbridge_backend.store import SequenceStore
from backend.signbridge_backend.websocket_api import LiveTrackingWebSocket


class FakeEmotionAnalyzer:
    def analyze(self, image_bytes: bytes) -> dict:
        assert image_bytes == b"fake-jpeg"
        return {
            "status": "ok",
            "dominant_emotion": "happy",
            "confidence": 0.86,
            "emotions": {"happy": 0.86, "neutral": 0.14},
            "model": "DeepFace",
        }


def payload(*, frame_count: int = 1) -> dict:
    empty_worlds = {
        "left_hand": {"handedness": "left", "confidence": 0, "landmarks": []},
        "right_hand": {"handedness": "right", "confidence": 0, "landmarks": []},
        "pose": {"landmarks": []},
        "face": {"upper": [], "mouth": [], "emotion": None},
    }
    frames = [
        {
            "timestamp": "2026-09-05T08:14:02.000Z",
            "tracking_confidence": 0.95,
            "hands": [],
            "face_expression": {"label": "neutral", "confidence": 0.9},
            "landmark_worlds": empty_worlds,
        }
        for _ in range(frame_count)
    ]
    return {
        "session_id": "session-test",
        "sequence_id": "sequence-test",
        "language": "ASL",
        "started_at": frames[0]["timestamp"],
        "ended_at": frames[-1]["timestamp"],
        "frame_count": frame_count,
        "lexicon_version": "2026-09-seed-2",
        "frames": frames,
    }


class BackendTests(unittest.TestCase):
    def test_validates_the_four_landmark_worlds(self) -> None:
        value = payload()
        point = {"index": 0, "name": "wrist", "x": 0.5, "y": 0.6, "z": 0.0}
        value["frames"][0]["landmark_worlds"] = {
            "left_hand": {
                "handedness": "left",
                "confidence": 0.9,
                "landmarks": [point] * 21,
            },
            "right_hand": {
                "handedness": "right",
                "confidence": 0.8,
                "landmarks": [point] * 21,
            },
            "pose": {
                "landmarks": [
                    {"index": index, "name": f"pose_{index}", "x": 0.5, "y": 0.5, "z": 0}
                    for index in range(11)
                ],
            },
            "face": {
                "upper": [
                    {"index": index, "name": "eye", "x": 0.5, "y": 0.4, "z": 0}
                    for index in range(24)
                ],
                "mouth": [
                    {"index": index, "name": "mouth", "x": 0.5, "y": 0.6, "z": 0}
                    for index in range(12)
                ],
                "emotion": None,
            },
        }
        parsed = SignSequencePayload.from_dict(value)
        self.assertEqual(len(parsed.frames[0]["landmark_worlds"]["pose"]["landmarks"]), 11)

    def test_validates_and_analyzes_no_signal(self) -> None:
        parsed = SignSequencePayload.from_dict(payload())
        result = SignBridgeBackend().analyze(parsed)
        self.assertEqual(result["status"], "no_signal")
        self.assertEqual(result["language"], "ASL")

    def test_rejects_frame_count_mismatch(self) -> None:
        value = payload()
        value["frame_count"] = 2
        with self.assertRaises(PayloadValidationError):
            SignSequencePayload.from_dict(value)

    def test_stores_the_sequence_and_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sequences.jsonl"
            service = SignBridgeBackend(store=SequenceStore(path))
            service.analyze(SignSequencePayload.from_dict(payload()))
            self.assertEqual(SequenceStore(path).count(), 1)

    def test_http_endpoint_matches_flutter_contract(self) -> None:
        server = create_server("127.0.0.1", 0, SignBridgeBackend())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            address = server.server_address
            request = Request(
                f"http://{address[0]}:{address[1]}/v1/sign-sequences/analyze",
                data=json.dumps(payload()).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urlopen(request, timeout=2) as response:
                result = json.loads(response.read().decode("utf-8"))
            self.assertEqual(result["status"], "no_signal")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_http_emotion_endpoint_returns_deepface_result(self) -> None:
        server = create_server(
            "127.0.0.1",
            0,
            SignBridgeBackend(emotion_analyzer=FakeEmotionAnalyzer()),
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            address = server.server_address
            request = Request(
                f"http://{address[0]}:{address[1]}/v1/emotions/analyze",
                data=b"fake-jpeg",
                headers={"Content-Type": "image/jpeg"},
                method="POST",
            )
            with urlopen(request, timeout=2) as response:
                result = json.loads(response.read().decode("utf-8"))
            self.assertEqual(result["dominant_emotion"], "happy")
            self.assertEqual(result["model"], "DeepFace")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_websocket_accepts_live_coordinate_frames(self) -> None:
        from websockets.sync.client import connect

        server = LiveTrackingWebSocket("127.0.0.1", 0)
        server.start()
        try:
            with connect(
                f"ws://127.0.0.1:{server.bound_port}/v1/tracking",
                open_timeout=2,
            ) as connection:
                ready = json.loads(connection.recv())
                self.assertEqual(ready["type"], "ready")
                connection.send(
                    json.dumps({"type": "start", "session_id": "ws-test"})
                )
                self.assertEqual(json.loads(connection.recv())["type"], "started")
                connection.send(
                    json.dumps(
                        {
                            "type": "frame",
                            "session_id": "ws-test",
                            "frame": payload()["frames"][0],
                        }
                    )
                )
                acknowledgement = json.loads(connection.recv())
                self.assertEqual(acknowledgement["type"], "frame_ack")
                self.assertEqual(acknowledgement["frames_received"], 1)
        finally:
            server.stop()

    def test_websocket_accepts_utterance_chunks(self) -> None:
        from websockets.sync.client import connect

        server = LiveTrackingWebSocket("127.0.0.1", 0)
        server.start()
        try:
            with connect(
                f"ws://127.0.0.1:{server.bound_port}/v1/tracking",
                open_timeout=2,
            ) as connection:
                self.assertEqual(json.loads(connection.recv())["type"], "ready")
                connection.send(
                    json.dumps({"type": "start", "session_id": "utterance-test"})
                )
                self.assertEqual(json.loads(connection.recv())["type"], "started")
                connection.send(
                    json.dumps(
                        {
                            "type": "utterance_start",
                            "session_id": "utterance-test",
                            "utterance_id": "utterance-1",
                        }
                    )
                )
                self.assertEqual(
                    json.loads(connection.recv())["type"], "utterance_started"
                )
                frame = payload()["frames"][0]
                frame["hand_motion"] = {
                    "average_velocity": 0.25,
                    "peak_velocity": 0.4,
                    "average_acceleration": 0.8,
                    "peak_acceleration": 1.1,
                    "direction": "right",
                    "per_hand": {
                        "left": {"velocity": 0.2, "acceleration": 0.7},
                        "right": {"velocity": 0.3, "acceleration": 0.9},
                    },
                }
                connection.send(
                    json.dumps(
                        {
                            "type": "chunk",
                            "session_id": "utterance-test",
                            "utterance_id": "utterance-1",
                            "chunk_id": "utterance-1-chunk-1",
                            "started_at": frame["timestamp"],
                            "ended_at": frame["timestamp"],
                            "frame_count": 1,
                            "frames": [frame],
                            "features": {
                                "average_velocity": 0.25,
                                "peak_velocity": 0.4,
                                "average_acceleration": 0.8,
                                "peak_acceleration": 1.1,
                                "direction": "right",
                            },
                        }
                    )
                )
                acknowledgement = json.loads(connection.recv())
                self.assertEqual(acknowledgement["type"], "chunk_ack")
                self.assertEqual(acknowledgement["frames_received"], 1)
                self.assertEqual(acknowledgement["chunks_received"], 1)

                # Chunk transport is continuous; it must not stop at the
                # legacy 600-frame limit used by individual frame messages.
                long_chunk_frames = [dict(frame) for _ in range(600)]
                connection.send(
                    json.dumps(
                        {
                            "type": "chunk",
                            "session_id": "utterance-test",
                            "utterance_id": "utterance-1",
                            "chunk_id": "utterance-1-chunk-2",
                            "started_at": frame["timestamp"],
                            "ended_at": frame["timestamp"],
                            "frame_count": len(long_chunk_frames),
                            "frames": long_chunk_frames,
                            "features": {},
                        }
                    )
                )
                long_acknowledgement = json.loads(connection.recv())
                self.assertEqual(long_acknowledgement["type"], "chunk_ack")
                self.assertEqual(long_acknowledgement["frames_received"], 601)
        finally:
            server.stop()


if __name__ == "__main__":
    unittest.main()
