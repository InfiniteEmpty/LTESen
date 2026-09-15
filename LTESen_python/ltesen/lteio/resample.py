"""Small NumPy-only sample-rate conversion helpers.

Integer downsampling uses a windowed-sinc anti-alias low-pass FIR before
sample selection.  This keeps the first receiver milestone dependency-light
while matching the important safety property of MATLAB's ``resample``.
Non-integer ratios use linear interpolation as a deterministic portability
fallback until a full polyphase resampler is added.
"""

from __future__ import annotations

from numbers import Real

import numpy as np


def resample_waveform(
    waveform: np.ndarray,
    input_rate_hz: float,
    output_rate_hz: float,
    *,
    output_length: int | None = None,
) -> np.ndarray:
    """Convert a waveform between two sample rates.

    ``waveform`` is shaped ``(samples,)`` or ``(samples, antennas)``.  For
    integer downsampling ratios, a short anti-alias low-pass FIR is applied
    before selecting the exact integer phase.  Other ratios use linear
    interpolation and are intentionally marked as a temporary portability
    fallback.
    """

    values = np.asarray(waveform)
    was_vector = values.ndim == 1
    if was_vector:
        values = values[:, None]
    if values.ndim != 2 or values.shape[0] == 0 or values.shape[1] == 0:
        raise ValueError("waveform must have shape (samples, antennas)")
    if not np.issubdtype(values.dtype, np.number) or not np.all(np.isfinite(values)):
        raise ValueError("waveform must be finite and numeric")
    if not isinstance(input_rate_hz, Real) or not np.isfinite(input_rate_hz) or input_rate_hz <= 0:
        raise ValueError("input_rate_hz must be positive and finite")
    if not isinstance(output_rate_hz, Real) or not np.isfinite(output_rate_hz) or output_rate_hz <= 0:
        raise ValueError("output_rate_hz must be positive and finite")

    input_rate = int(round(float(input_rate_hz)))
    output_rate = int(round(float(output_rate_hz)))
    if input_rate <= 0 or output_rate <= 0:
        raise ValueError("sample rates must round to positive integers")
    if output_length is None:
        target_count = int(np.ceil(values.shape[0] * output_rate / input_rate))
    else:
        if isinstance(output_length, bool) or not isinstance(output_length, int) or output_length <= 0:
            raise ValueError("output_length must be a positive integer")
        target_count = output_length

    if input_rate == output_rate:
        result = _resize_exact(values, target_count)
    else:
        ratio = input_rate / output_rate
        integer_downsample = ratio >= 1 and np.isclose(ratio, round(ratio), rtol=0, atol=1e-9)
        if integer_downsample:
            step = int(round(ratio))
            filtered = _anti_alias_filter(values, step)
            result = _resize_exact(filtered[::step, :], target_count)
        else:
            source_positions = np.arange(target_count, dtype=float) * input_rate / output_rate
            source_positions = np.minimum(source_positions, values.shape[0] - 1)
            source_indices = np.arange(values.shape[0], dtype=float)
            result = np.empty((target_count, values.shape[1]), dtype=np.complex64)
            for antenna in range(values.shape[1]):
                column = values[:, antenna]
                result[:, antenna] = np.interp(source_positions, source_indices, column.real)
                if np.iscomplexobj(column):
                    result[:, antenna] += 1j * np.interp(
                        source_positions, source_indices, column.imag
                    )

    if was_vector:
        return result[:, 0]
    return result


def _anti_alias_filter(values: np.ndarray, step: int) -> np.ndarray:
    """Apply a linear-phase low-pass FIR suitable for decimation by ``step``."""

    if step <= 1:
        return values.astype(np.complex64, copy=False)
    # The passband ends below the new Nyquist frequency.  A Hamming-windowed
    # sinc gives useful stop-band rejection without adding SciPy to the core
    # package.  The explicit edge padding avoids zero-filled transients when
    # the receiver processes one subframe at a time.
    cutoff = 0.45 / step
    half_width = max(8 * step, 16)
    taps = np.arange(-half_width, half_width + 1, dtype=float)
    coefficients = 2.0 * cutoff * np.sinc(2.0 * cutoff * taps)
    coefficients *= np.hamming(coefficients.size)
    coefficients /= np.sum(coefficients)

    padded = np.pad(values, ((half_width, half_width), (0, 0)), mode="edge")
    filtered = np.empty_like(padded, dtype=np.complex64)
    for antenna in range(values.shape[1]):
        filtered[:, antenna] = np.convolve(
            padded[:, antenna], coefficients, mode="same"
        )
    return filtered[half_width:-half_width, :]


def _resize_exact(values: np.ndarray, target_count: int) -> np.ndarray:
    if values.shape[0] >= target_count:
        return values[:target_count, :].astype(np.complex64, copy=False)
    result = np.empty((target_count, values.shape[1]), dtype=np.complex64)
    result[: values.shape[0], :] = values
    result[values.shape[0] :, :] = values[-1, :]
    return result


__all__ = ["resample_waveform"]
