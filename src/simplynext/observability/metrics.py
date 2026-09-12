"""Small in-process metrics registry for the single-worker MVP."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from threading import Lock


@dataclass(frozen=True, slots=True)
class TimingSnapshot:
    count: int
    total_ms: float
    minimum_ms: float
    maximum_ms: float

    @property
    def mean_ms(self) -> float:
        return self.total_ms / self.count if self.count else 0.0


@dataclass(slots=True)
class _Timing:
    count: int = 0
    total_ms: float = 0.0
    minimum_ms: float = float("inf")
    maximum_ms: float = 0.0

    def add(self, value_ms: float) -> None:
        self.count += 1
        self.total_ms += value_ms
        self.minimum_ms = min(self.minimum_ms, value_ms)
        self.maximum_ms = max(self.maximum_ms, value_ms)


class MetricsRegistry:
    """Thread-safe counters and latency aggregates without user payload data."""

    def __init__(self) -> None:
        self._counters: defaultdict[str, int] = defaultdict(int)
        self._timings: defaultdict[str, _Timing] = defaultdict(_Timing)
        self._lock = Lock()

    def increment(self, name: str, amount: int = 1) -> None:
        if amount < 0:
            raise ValueError("counter increments cannot be negative")
        with self._lock:
            self._counters[name] += amount

    def observe_ms(self, name: str, value_ms: float) -> None:
        if value_ms < 0:
            raise ValueError("latency cannot be negative")
        with self._lock:
            self._timings[name].add(value_ms)

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            counters = dict(sorted(self._counters.items()))
            timings = {
                name: {
                    "count": timing.count,
                    "mean_ms": timing.total_ms / timing.count if timing.count else 0.0,
                    "minimum_ms": 0.0 if timing.count == 0 else timing.minimum_ms,
                    "maximum_ms": timing.maximum_ms,
                }
                for name, timing in sorted(self._timings.items())
            }
        return {"counters": counters, "timings": timings}
