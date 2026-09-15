"""Single owner of raw-file position and LTE frame/subframe numbering."""

from __future__ import annotations

import math
from collections.abc import Mapping
from typing import Any


class Timebase:
    """Track a raw sample cursor alongside LTE-domain timing metadata."""

    def __init__(self, lock: Mapping[str, Any] | Any) -> None:
        self.reset(lock)

    def reset(self, lock: Mapping[str, Any] | Any) -> None:
        self.epoch = float(_field(lock, "epoch", "Epoch"))
        self.sequence = 0
        self.raw_sample_rate_hz = float(_field(lock, "raw_sample_rate_hz", "RawSampleRateHz"))
        self.reported_raw_sample_rate_hz = float(
            _field(
                lock,
                "reported_raw_sample_rate_hz",
                "ReportedRawSampleRateHz",
                default=self.raw_sample_rate_hz,
            )
        )
        self.lte_sample_rate_hz = float(_field(lock, "lte_sample_rate_hz", "LteSampleRateHz"))
        self.raw_samples_per_subframe = self.raw_sample_rate_hz / 1000.0
        self.lte_samples_per_subframe = _round_positive(self.lte_sample_rate_hz / 1000.0)
        self.current_raw_start_exact = float(
            _field(lock, "raw_frame_start_sample_0", "RawFrameStartSample0")
        )
        enb = _field(lock, "enb", "Enb", default={})
        self.frame_number = float(_field(enb, "n_frame", "NFrame", default=0))
        self.subframe_number = 0
        self.last_timing_correction_lte_samples = 0

    def can_read(self, sample_count: int | float) -> bool:
        start_sample_0 = _round_positive(self.current_raw_start_exact)
        return start_sample_0 + _round_positive(self.raw_samples_per_subframe) <= sample_count

    def current_meta(self) -> dict[str, Any]:
        start_sample_0 = _round_positive(self.current_raw_start_exact)
        sample_count = _round_positive(self.raw_samples_per_subframe)
        timestamp = (
            start_sample_0 / self.reported_raw_sample_rate_hz
            if self.reported_raw_sample_rate_hz > 0
            else math.nan
        )
        return {
            "epoch": self.epoch,
            "sequence": self.sequence,
            "raw_start_sample_0": start_sample_0,
            "raw_end_sample_0": start_sample_0 + sample_count,
            "raw_sample_count": sample_count,
            "raw_sample_rate_hz": self.raw_sample_rate_hz,
            "reported_raw_sample_rate_hz": self.reported_raw_sample_rate_hz,
            "lte_sample_rate_hz": self.lte_sample_rate_hz,
            "timestamp_seconds": timestamp,
            "frame_number": self.frame_number,
            "subframe_number": self.subframe_number,
        }

    def advance(self, timing_delta_lte_samples: int | float = 0) -> None:
        delta = self._validate_timing_delta(timing_delta_lte_samples)
        self.current_raw_start_exact += (
            self.raw_samples_per_subframe + self._to_raw_samples(delta)
        )
        self.sequence += 1
        self.subframe_number += 1
        if self.subframe_number == 10:
            self.subframe_number = 0
            self.frame_number = (self.frame_number + 1) % 1024

    def apply_timing_correction(self, timing_delta_lte_samples: int | float = 0) -> None:
        """Adjust the next read position without advancing sequence time.

        The receiver uses this at an LTE-frame boundary.  Phase/SFO tracking
        remains continuous for every subframe, while the discrete integer
        sample correction is applied only once to the start of the next frame.
        """

        delta = self._validate_timing_delta(timing_delta_lte_samples)
        self.current_raw_start_exact += self._to_raw_samples(delta)
        self.last_timing_correction_lte_samples = int(round(delta))

    def _validate_timing_delta(self, value: int | float) -> float:
        delta = float(value)
        if not math.isfinite(delta):
            raise ValueError("timing_delta_lte_samples must be finite")
        return delta

    def _to_raw_samples(self, delta_lte_samples: float) -> float:
        return delta_lte_samples * self.raw_sample_rate_hz / self.lte_sample_rate_hz


def _field(
    value: Mapping[str, Any] | Any,
    python_name: str,
    matlab_name: str,
    *,
    default: Any = ...,
) -> Any:
    if isinstance(value, Mapping):
        if python_name in value:
            return value[python_name]
        if matlab_name in value:
            return value[matlab_name]
    else:
        if hasattr(value, python_name):
            return getattr(value, python_name)
        if hasattr(value, matlab_name):
            return getattr(value, matlab_name)
    if default is not ...:
        return default
    raise ValueError(f"Missing timebase field: {python_name}")


def _round_positive(value: float) -> int:
    if not math.isfinite(value):
        raise ValueError("timebase sample quantities must be finite")
    return math.floor(value + 0.5)


__all__ = ["Timebase"]
