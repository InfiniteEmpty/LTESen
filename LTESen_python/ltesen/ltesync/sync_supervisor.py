"""Synchronization-health monitoring for the streaming receiver."""

from __future__ import annotations

from math import isfinite
from numbers import Integral, Real
from typing import Any, Mapping


class SyncSupervisor:
    """Turn repeated low CP-correlation quality into a reacquisition event."""

    def __init__(self, config: Mapping[str, Any] | None = None) -> None:
        self.config = dict(config or {})
        self.enabled = bool(self.config.get("enable_monitoring", True))
        self.suspect_threshold = _finite_real(
            self.config.get("suspect_threshold", 0.20), "suspect_threshold"
        )
        self.lost_threshold = _finite_real(
            self.config.get("lost_threshold", 0.10), "lost_threshold"
        )
        self.consecutive_failures = _positive_int(
            self.config.get("consecutive_failures", 3), "consecutive_failures"
        )
        if self.lost_threshold > self.suspect_threshold:
            raise ValueError("lost_threshold must not exceed suspect_threshold")
        self.reset()

    def observe(self, quality: float, meta: Mapping[str, Any]) -> dict[str, Any]:
        """Observe one normalized quality value and return an event mapping."""

        self.last_quality = float(quality)
        event = {
            "available": False,
            "type": "",
            "epoch": meta.get("epoch", meta.get("Epoch")),
            "payload": {},
        }
        if not self.enabled or not isfinite(self.last_quality):
            return event
        if self.last_quality < self.lost_threshold:
            self.consecutive_failure_count += 1
        elif self.last_quality < self.suspect_threshold:
            self.state = "suspect"
            self.consecutive_failure_count = max(1, self.consecutive_failure_count)
        else:
            self.state = "locked"
            self.consecutive_failure_count = 0
        if self.consecutive_failure_count >= self.consecutive_failures:
            self.state = "lost"
            event.update(
                {
                    "available": True,
                    "type": "resync_requested",
                    "payload": {
                        "expected_raw_sample_0": meta.get(
                            "raw_end_sample_0", meta.get("RawEndSample0")
                        ),
                        "reason": "tracking-quality",
                    },
                }
            )
        return event

    def reset(self) -> None:
        self.state = "locked"
        self.consecutive_failure_count = 0
        self.last_quality = float("nan")

    def get_status(self) -> dict[str, Any]:
        return {
            "state": self.state,
            "ready": self.state == "locked",
            "consecutive_failure_count": self.consecutive_failure_count,
            "last_quality": self.last_quality,
        }


def _finite_real(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, Real) or not isfinite(value):
        raise ValueError(f"{name} must be finite")
    return float(value)


def _positive_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be a positive integer")
    if not isfinite(value) or int(value) != value or int(value) <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return int(value)


__all__ = ["SyncSupervisor"]
