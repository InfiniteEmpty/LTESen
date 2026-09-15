"""Recursive cyclic-prefix CFO refinement for the streaming receiver."""

from __future__ import annotations

from numbers import Real
from typing import Any, Mapping

import numpy as np


class CfoTracker:
    """Track CFO from CPs while updating the correction vector periodically.

    CP measurements are collected for every subframe so that the receiver can
    monitor synchronization continuously.  The applied correction frequency
    is changed only after a window of measurements has been averaged; this is
    appropriate for the slow oscillator drift expected from the receiver.
    """

    def __init__(self, config: Mapping[str, Any] | None, lock: Any) -> None:
        self.config = dict(config or {})
        info = _field(lock, "ofdm_info", "OfdmInfo")
        self.nfft = int(_field(info, "nfft", "Nfft"))
        self.cp_lengths = tuple(
            int(item)
            for item in _field(
                info,
                "cyclic_prefix_lengths",
                "cp_lengths",
                "CyclicPrefixLengths",
            )
        )
        self.sample_rate_hz = float(
            _field(lock, "lte_sample_rate_hz", "LteSampleRateHz")
        )
        self.sample_count = int(round(self.sample_rate_hz / 1000.0))
        self.cfo_hz = float(_field(lock, "initial_cfo_hz", "InitialCfoHz"))
        self.residual_cfo_hz = float("nan")
        self.last_cp_correlation = float("nan")
        self.refinement_enabled = bool(
            self.config.get("cfo_refinement_enabled", True)
        )
        self.refinement_interval_subframes = _positive_int(
            self.config.get("cfo_refinement_interval_subframes", 100),
            "cfo_refinement_interval_subframes",
        )
        self._sample_index = np.arange(self.sample_count, dtype=np.float32)
        self._correction_phase: np.ndarray | None = None
        self._phase_cfo_hz = float("nan")
        self._subframe_index = 0
        self._residual_sum_hz = 0.0
        self._residual_count = 0
        self.last_refinement_delta_hz = 0.0

    def correct(self, waveform: np.ndarray) -> tuple[np.ndarray, dict[str, float]]:
        """Correct one LTE subframe and return correction quality metrics."""

        values = np.asarray(waveform, dtype=np.complex64)
        if values.ndim == 1:
            values = values[:, None]
        if values.ndim != 2 or values.shape[0] != self.sample_count:
            raise ValueError(
                f"waveform must contain exactly {self.sample_count} LTE samples"
            )
        if not np.all(np.isfinite(values)):
            raise ValueError("waveform must contain finite values")

        front_start = _nonnegative_int(
            self.config.get("cfo_cp_start_sample", 10), "cfo_cp_start_sample"
        )
        guard = _nonnegative_int(
            self.config.get("cfo_cp_guard_samples", 20), "cfo_cp_guard_samples"
        )
        tail_start = front_start + self.nfft
        mixed = 0.0 + 0.0j
        normalization = 0.0
        for cp_length in self.cp_lengths:
            cp_use = cp_length - guard
            if cp_use <= 0 or tail_start + cp_use > values.shape[0]:
                raise ValueError("configured CP correlation window is invalid")
            front = values[front_start : front_start + cp_use, 0]
            tail = values[tail_start : tail_start + cp_use, 0]
            mixed += np.sum(tail * np.conj(front))
            normalization += float(
                np.sqrt(np.sum(np.abs(front) ** 2) * np.sum(np.abs(tail) ** 2))
            )
            front_start += self.nfft + cp_length
            tail_start += self.nfft + cp_length

        radians_to_hz = self.sample_rate_hz / self.nfft / (2 * np.pi)
        wrapped_total_cfo_hz = float(np.angle(mixed) * radians_to_hz)
        ambiguity_period_hz = self.sample_rate_hz / self.nfft
        residual = wrapped_total_cfo_hz - self.cfo_hz
        residual -= round(residual / ambiguity_period_hz) * ambiguity_period_hz
        self.residual_cfo_hz = float(residual)
        if self.refinement_enabled and np.isfinite(self.residual_cfo_hz):
            self._residual_sum_hz += self.residual_cfo_hz
            self._residual_count += 1
            if self._residual_count >= self.refinement_interval_subframes:
                mean_residual_hz = self._residual_sum_hz / self._residual_count
                self.cfo_hz += mean_residual_hz
                self.last_refinement_delta_hz = float(mean_residual_hz)
                self._correction_phase = None
                self._residual_sum_hz = 0.0
                self._residual_count = 0
        self.last_cp_correlation = float(abs(mixed) / max(normalization, np.finfo(float).eps))
        if self._correction_phase is None or self._phase_cfo_hz != self.cfo_hz:
            phase_argument = np.asarray(
                -2 * np.pi * self.cfo_hz * self._sample_index / self.sample_rate_hz,
                dtype=np.float32,
            )
            self._correction_phase = np.exp(
                np.asarray(1j * phase_argument, dtype=np.complex64)
            ).astype(np.complex64, copy=False)
            self._phase_cfo_hz = self.cfo_hz
        corrected = values * self._correction_phase[:, None]
        self._subframe_index += 1
        return corrected, {
            "cfo_hz": self.cfo_hz,
            "residual_cfo_hz": self.residual_cfo_hz,
            "cp_correlation": self.last_cp_correlation,
            "cfo_refinement_pending_subframes": self._residual_count,
            "last_refinement_delta_hz": self.last_refinement_delta_hz,
        }

    def get_status(self) -> dict[str, float | str | bool]:
        return {
            "state": "ready",
            "ready": True,
            "cfo_hz": self.cfo_hz,
            "residual_cfo_hz": self.residual_cfo_hz,
            "cp_correlation": self.last_cp_correlation,
            "cfo_refinement_pending_subframes": self._residual_count,
            "last_refinement_delta_hz": self.last_refinement_delta_hz,
        }


def _nonnegative_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return value


def _positive_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return value


def _field(value: Mapping[str, Any] | Any, *names: str) -> Any:
    if isinstance(value, Mapping):
        for name in names:
            if name in value:
                return value[name]
    else:
        for name in names:
            if hasattr(value, name):
                return getattr(value, name)
    raise ValueError(f"Missing lock field; expected one of {names}")


__all__ = ["CfoTracker"]
