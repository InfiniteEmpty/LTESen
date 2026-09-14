"""Fast phase-slope estimation used by the CSI tracker."""

from __future__ import annotations

import numpy as np


def estimate_phase_slope_fft(signal: np.ndarray) -> np.ndarray:
    """Estimate a dominant phase slope along the first axis.

    This is the NumPy translation of ``estimatePhaseSlopeFFT.m``.  The
    returned shape is ``(1, *signal.shape[1:])`` and the estimate is expressed
    in samples of the original first-axis length.
    """

    values = np.asarray(signal)
    if values.ndim == 0:
        raise ValueError("signal must have at least one dimension")
    if values.shape[0] == 0:
        raise ValueError("signal must not be empty")
    if not np.issubdtype(values.dtype, np.number):
        raise TypeError("signal must be numeric")

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


__all__ = ["estimate_phase_slope_fft"]
