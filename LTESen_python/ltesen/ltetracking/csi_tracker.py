"""Phase/SFO correction and stateful static CSI tracking."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np


class CsiTracker:
    """Correct CRS phase slope and maintain static/dynamic CSI estimates.

    This is the Python counterpart of ``ltetracking.CsiTracker``.  The
    tracker keeps the IIR filter state between frames, so a frame boundary
    does not reset the static CSI estimate.
    """

    def __init__(self, config: Mapping[str, Any] | None, context: Mapping[str, Any] | Any) -> None:
        self.config = dict(config or {})
        enb = _field(context, "enb", "Enb")
        info = _field(context, "ofdm_info", "OfdmInfo")
        self.nfft = _positive_int(_field(info, "nfft", "Nfft"), "nfft")
        ndlrb = _positive_int(_field(enb, "ndlrb", "NDLRB"), "ndlrb")
        self.carrier_count = ndlrb * 12
        self.ncrs = ndlrb * 2
        self.nrx = _positive_int(
            _field(context, "receive_antenna_count", "ReceiveAntennaCount"),
            "receive_antenna_count",
        )
        self.ntx = _positive_int(_field(enb, "cell_ref_p", "CellRefP"), "cell_ref_p")

        filter_order = _nonnegative_int(
            self.config.get("static_filter_order", 4), "static_filter_order"
        )
        cutoff = float(self.config.get("static_filter_cutoff", np.pi / 512.0))
        if not np.isfinite(cutoff) or not 0 < cutoff < 1:
            raise ValueError("static_filter_cutoff must be in (0, 1)")
        self.filter_b, self.filter_a = _butter_lowpass(filter_order, cutoff)
        state_shape = (self.ncrs, self.nrx, self.ntx)
        filter_state_order = max(self.filter_a.size, self.filter_b.size) - 1
        self._filter_state_g1 = np.zeros(
            (filter_state_order,) + state_shape, dtype=np.complex64
        )
        self._filter_state_g2 = np.zeros_like(self._filter_state_g1)
        self._static_g1 = np.ones((self.ncrs, 1, self.nrx, self.ntx), dtype=np.complex64)
        self._static_g2 = np.ones_like(self._static_g1)
        self.sample_count = 0
        self.last_sample_shift = float("nan")
        self.last_timing_delta_lte_samples = 0

    def correct(
        self,
        csi_g1: np.ndarray,
        csi_g2: np.ndarray,
        index_g1: np.ndarray,
        index_g2: np.ndarray,
    ) -> tuple[dict[str, np.ndarray], dict[str, Any]]:
        """Correct one two-symbol CRS batch and return data plus quality."""

        values_g1 = _as_csi(csi_g1, self.ncrs, self.nrx, self.ntx, "csi_g1")
        values_g2 = _as_csi(csi_g2, self.ncrs, self.nrx, self.ntx, "csi_g2")
        locations_g1 = _as_indices(index_g1, self.ncrs, self.ntx, "index_g1")
        locations_g2 = _as_indices(index_g2, self.ncrs, self.ntx, "index_g2")
        frequency_g1 = (locations_g1[:, 0].astype(float) - self.carrier_count / 2.0).reshape(
            self.ncrs, 1, 1, 1
        )
        frequency_g2 = (locations_g2[:, 0].astype(float) - self.carrier_count / 2.0).reshape(
            self.ncrs, 1, 1, 1
        )

        if self.sample_count == 0:
            self._static_g1 = values_g1[:, 0:1, :, :].copy()
            self._static_g2 = values_g2[:, 0:1, :, :].copy()

        corrected_g1 = np.empty_like(values_g1)
        corrected_g2 = np.empty_like(values_g2)
        dynamic_g1 = np.empty_like(values_g1)
        dynamic_g2 = np.empty_like(values_g2)
        shifts: list[float] = []
        for time_index in range(values_g1.shape[1]):
            (
                corrected_g1[:, time_index : time_index + 1, :, :],
                dynamic_g1[:, time_index : time_index + 1, :, :],
                self._static_g1,
                self._filter_state_g1,
                shift_g1,
            ) = self._correct_one(
                values_g1[:, time_index : time_index + 1, :, :],
                self._static_g1,
                self._filter_state_g1,
                frequency_g1,
            )
            (
                corrected_g2[:, time_index : time_index + 1, :, :],
                dynamic_g2[:, time_index : time_index + 1, :, :],
                self._static_g2,
                self._filter_state_g2,
                shift_g2,
            ) = self._correct_one(
                values_g2[:, time_index : time_index + 1, :, :],
                self._static_g2,
                self._filter_state_g2,
                frequency_g2,
            )
            shifts.extend((shift_g1, shift_g2))

        self.last_sample_shift = float(np.mean(shifts))
        self.last_timing_delta_lte_samples = -int(np.rint(self.last_sample_shift))
        self.sample_count += 1
        data = {
            "g1": corrected_g1,
            "g2": corrected_g2,
            "dynamic_g1": dynamic_g1,
            "dynamic_g2": dynamic_g2,
            "index_g1": locations_g1,
            "index_g2": locations_g2,
        }
        quality = {
            "sample_shift": self.last_sample_shift,
            "timing_delta_lte_samples": self.last_timing_delta_lte_samples,
            "static_estimate_ready": self.sample_count > 1,
        }
        return data, quality

    def correct_frame(
        self,
        csi_g1: np.ndarray,
        csi_g2: np.ndarray,
        index_g1: np.ndarray,
        index_g2: np.ndarray,
    ) -> tuple[dict[str, np.ndarray], dict[str, Any]]:
        """Correct one LTE frame using one static reference update.

        The phase-slope FFT is evaluated once over all CRS time samples in
        the frame.  The static reference used for correction is held fixed
        throughout the frame and updated from the frame average afterwards.
        This preserves the tracker state across frames while avoiding one
        peak-search FFT per CRS symbol.
        """

        values_g1 = _as_csi_frame(csi_g1, self.ncrs, self.nrx, self.ntx, "csi_g1")
        values_g2 = _as_csi_frame(csi_g2, self.ncrs, self.nrx, self.ntx, "csi_g2")
        locations_g1 = _as_indices(index_g1, self.ncrs, self.ntx, "index_g1")
        locations_g2 = _as_indices(index_g2, self.ncrs, self.ntx, "index_g2")
        if values_g1.shape[1] != values_g2.shape[1]:
            raise ValueError("csi_g1 and csi_g2 must contain the same frame length")

        frequency_g1 = (
            locations_g1[:, 0].astype(float) - self.carrier_count / 2.0
        ).reshape(self.ncrs, 1, 1, 1)
        frequency_g2 = (
            locations_g2[:, 0].astype(float) - self.carrier_count / 2.0
        ).reshape(self.ncrs, 1, 1, 1)

        if self.sample_count == 0:
            self._static_g1 = values_g1[:, 0:1, :, :].copy()
            self._static_g2 = values_g2[:, 0:1, :, :].copy()

        normalized_g1 = _normalize_csi(values_g1)
        normalized_g2 = _normalize_csi(values_g2)
        difference_g1 = normalized_g1 * np.conj(self._static_g1)
        difference_g2 = normalized_g2 * np.conj(self._static_g2)
        normalized_combined = np.concatenate((normalized_g1, normalized_g2), axis=1)
        combined_difference = np.concatenate((difference_g1, difference_g2), axis=1)

        shift_tensor = _estimate_phase_slope_fft(combined_difference) * (
            self.nfft / self.carrier_count
        )
        frame_length = values_g1.shape[1]
        combined_frequency = np.concatenate(
            (
                np.broadcast_to(
                    frequency_g1,
                    (self.ncrs, frame_length, 1, 1),
                ),
                np.broadcast_to(
                    frequency_g2,
                    (self.ncrs, frame_length, 1, 1),
                ),
            ),
            axis=1,
        )
        correction = np.exp(
            np.asarray(
                -2j * np.pi / self.nfft * shift_tensor * combined_frequency,
                dtype=np.complex64,
            )
        ).astype(np.complex64, copy=False)
        phase_bias = np.angle(
            np.sum(combined_difference * correction, axis=0, keepdims=True)
        )
        corrected_combined = (
            normalized_combined
            * correction
            * np.exp(np.asarray(-1j * phase_bias, dtype=np.complex64))
        )
        corrected_g1 = corrected_combined[:, :frame_length, :, :]
        corrected_g2 = corrected_combined[:, frame_length:, :, :]

        self._static_g1, self._filter_state_g1 = _update_static_once(
            corrected_g1,
            self._filter_state_g1,
            self.filter_b,
            self.filter_a,
        )
        self._static_g2, self._filter_state_g2 = _update_static_once(
            corrected_g2,
            self._filter_state_g2,
            self.filter_b,
            self.filter_a,
        )
        dynamic_g1 = corrected_g1 - self._static_g1
        dynamic_g2 = corrected_g2 - self._static_g2

        self.last_sample_shift = float(np.mean(shift_tensor).real)
        self.last_timing_delta_lte_samples = -int(np.rint(self.last_sample_shift))
        self.sample_count += 1
        data = {
            "g1": corrected_g1,
            "g2": corrected_g2,
            "dynamic_g1": dynamic_g1,
            "dynamic_g2": dynamic_g2,
            "index_g1": locations_g1,
            "index_g2": locations_g2,
        }
        quality = {
            "sample_shift": self.last_sample_shift,
            "timing_delta_lte_samples": self.last_timing_delta_lte_samples,
            "static_estimate_ready": self.sample_count > 1,
            "static_update_samples": frame_length,
        }
        return data, quality

    def get_status(self) -> dict[str, Any]:
        return {
            "state": "ready" if self.sample_count > 1 else "warming",
            "ready": self.sample_count > 1,
            "warmup_count": min(self.sample_count, 2),
            "warmup_required": 2,
            "sample_count": self.sample_count,
            "last_sample_shift": self.last_sample_shift,
            "last_timing_delta_lte_samples": self.last_timing_delta_lte_samples,
        }

    def _correct_one(
        self,
        values: np.ndarray,
        static_estimate: np.ndarray,
        filter_state: np.ndarray,
        frequency: np.ndarray,
    ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, float]:
        normalized = _normalize_csi(values)
        difference = normalized * np.conj(static_estimate)
        shift_tensor = _estimate_phase_slope_fft(difference) * (
            self.nfft / self.carrier_count
        )
        correction = np.exp(
            np.asarray(
                -2j * np.pi / self.nfft * shift_tensor * frequency,
                dtype=np.complex64,
            )
        ).astype(np.complex64, copy=False)
        phase_bias = np.angle(
            np.sum(difference * correction, axis=0, keepdims=True)
        )
        corrected = normalized * correction * np.exp(
            np.asarray(-1j * phase_bias, dtype=np.complex64)
        )
        current_row = np.transpose(corrected, (1, 0, 2, 3))
        static_row, filter_state = _filter_chunk(
            self.filter_b, self.filter_a, current_row, filter_state
        )
        new_static = np.transpose(static_row, (1, 0, 2, 3))
        dynamic = corrected - new_static
        return corrected, dynamic, new_static, filter_state, float(np.mean(shift_tensor).real)


def _estimate_phase_slope_fft(signal: np.ndarray) -> np.ndarray:
    """Estimate phase slope along the first axis with a zero-padded FFT.

    This is an implementation detail of :class:`CsiTracker`; it lives next
    to the stateful correction algorithm because no other pipeline component
    uses this particular phase model.
    """

    values = np.asarray(signal)
    if values.ndim == 0:
        raise ValueError("signal must have at least one dimension")
    if values.shape[0] == 0:
        raise ValueError("signal must not be empty")
    if not np.issubdtype(values.dtype, np.number):
        raise ValueError("signal must contain numeric values")

    n_samples = values.shape[0]
    n_pad = max(1024, 1 << int(np.ceil(np.log2(n_samples * 4))))
    spectrum = np.fft.fft(values, n=n_pad, axis=0)
    magnitude = np.abs(spectrum) ** 2
    flat = magnitude.reshape(n_pad, -1)
    peak_indices = np.argmax(flat, axis=0)
    columns = np.arange(flat.shape[1])
    peak = flat[peak_indices, columns]
    left = flat[(peak_indices - 1) % n_pad, columns]
    right = flat[(peak_indices + 1) % n_pad, columns]
    denominator = left - 2 * peak + right
    denominator = np.where(denominator == 0, np.finfo(float).eps, denominator)
    delta = 0.5 * (left - right) / denominator
    peak_position = peak_indices.astype(float) + delta
    fft_index = peak_position.copy()
    fft_index[fft_index > n_pad / 2] -= n_pad
    result = (fft_index / n_pad * n_samples).reshape((1,) + values.shape[1:])
    return result


def _normalize_csi(values: np.ndarray) -> np.ndarray:
    scale = np.linalg.norm(values, axis=0, keepdims=True)
    scale = np.where(scale == 0, 1.0, scale)
    return values / scale


def _update_static_once(
    corrected: np.ndarray,
    filter_state: np.ndarray,
    numerator: np.ndarray,
    denominator: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    frame_average = np.mean(corrected, axis=1, keepdims=True).astype(
        np.complex64, copy=False
    )
    current_row = np.transpose(frame_average, (1, 0, 2, 3))
    static_row, filter_state = _filter_chunk(
        numerator,
        denominator,
        current_row,
        filter_state,
    )
    return np.transpose(static_row, (1, 0, 2, 3)), filter_state


def _butter_lowpass(order: int, cutoff: float) -> tuple[np.ndarray, np.ndarray]:
    """Design a digital Butterworth low-pass filter without SciPy."""

    if order == 0:
        return np.asarray([1.0]), np.asarray([1.0])
    # Bilinear transform of the normalized analog Butterworth poles.  The
    # cutoff follows MATLAB/scipy's normalized-to-Nyquist convention.  The
    # analog poles must all be in the left half-plane; using ``-exp(j*theta)``
    # here puts half of them in the right half-plane for order >= 3 and makes
    # the resulting digital filter unstable, especially at a very low cutoff.
    theta = np.pi * (2 * np.arange(order) + 1) / (2 * order)
    poles = -np.sin(theta) + 1j * np.cos(theta)
    warped_cutoff = 2.0 * np.tan(np.pi * cutoff / 2.0)
    analog_poles = warped_cutoff * poles
    digital_poles = (2.0 + analog_poles) / (2.0 - analog_poles)
    numerator = np.poly(-np.ones(order)).real
    denominator = np.poly(digital_poles).real
    numerator *= np.sum(denominator) / np.sum(numerator)
    return numerator, denominator


def _filter_chunk(
    numerator: np.ndarray,
    denominator: np.ndarray,
    values: np.ndarray,
    state: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    """Filter along axis zero using direct-form II transposed state."""

    if values.ndim < 1 or state.shape[1:] != values.shape[1:]:
        raise ValueError("filter state shape does not match CSI input")
    order = state.shape[0]
    output = np.empty_like(values, dtype=np.complex64)
    a0 = denominator[0]
    for index, sample in enumerate(values):
        current = (numerator[0] * sample + (state[0] if order else 0)) / a0
        output[index] = current
        if order:
            if order > 1:
                state[:-1] = (
                    state[1:]
                    + numerator[1:order, None, None, None] * sample
                    - denominator[1:order, None, None, None] * current
                )
            state[-1] = (
                numerator[order] * sample - denominator[order] * current
            )
    return output, state


def _as_csi(
    value: np.ndarray,
    ncrs: int,
    nrx: int,
    ntx: int,
    name: str,
) -> np.ndarray:
    array = np.asarray(value, dtype=np.complex64)
    expected = (ncrs, 2, nrx, ntx)
    if array.shape != expected or not np.all(np.isfinite(array)):
        raise ValueError(f"{name} must have shape {expected} and contain finite values")
    return array


def _as_csi_frame(
    value: np.ndarray,
    ncrs: int,
    nrx: int,
    ntx: int,
    name: str,
) -> np.ndarray:
    array = np.asarray(value, dtype=np.complex64)
    if (
        array.ndim != 4
        or array.shape[0] != ncrs
        or array.shape[1] <= 0
        or array.shape[2:] != (nrx, ntx)
        or not np.all(np.isfinite(array))
    ):
        raise ValueError(
            f"{name} must have shape ({ncrs}, time, {nrx}, {ntx}) "
            "and contain finite values"
        )
    return array


def _as_indices(value: np.ndarray, ncrs: int, ntx: int, name: str) -> np.ndarray:
    array = np.asarray(value)
    expected = (ncrs, ntx)
    if array.shape != expected or not np.issubdtype(array.dtype, np.number):
        raise ValueError(f"{name} must have shape {expected}")
    if not np.all(np.isfinite(array)):
        raise ValueError(f"{name} must contain finite values")
    return array.astype(np.int64, copy=False)


def _positive_int(value: Any, name: str) -> int:
    integer = _nonnegative_int(value, name)
    if integer <= 0:
        raise ValueError(f"{name} must be positive")
    return integer


def _nonnegative_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be an integer")
    if not np.isfinite(value) or int(value) != value or int(value) < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return int(value)


def _field(value: Mapping[str, Any] | Any, *names: str) -> Any:
    if isinstance(value, Mapping):
        for name in names:
            if name in value:
                return value[name]
    else:
        for name in names:
            if hasattr(value, name):
                return getattr(value, name)
    raise ValueError(f"Missing tracking field; expected one of {names}")


__all__ = ["CsiTracker"]
