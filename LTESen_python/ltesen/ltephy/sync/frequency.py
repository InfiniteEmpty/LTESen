"""Frequency-offset estimation and correction for LTE waveforms."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from ltesen.ltephy.common import lte_ofdm_info


def lte_frequency_correct(
    cfg: Mapping[str, Any] | Any,
    waveform: np.ndarray,
    offset_hz: float,
) -> np.ndarray:
    """Apply the negative of ``offset_hz`` to a time-domain waveform.

    This follows ``lteFrequencyCorrect``: a positive input offset is removed
    by multiplying sample ``n`` by ``exp(-j*2*pi*offset*n/Fs)``.  Both
    ``(samples,)`` and ``(samples, antennas)`` arrays are accepted.
    """

    values, was_vector = _as_waveform(waveform)
    sample_rate = _sample_rate(cfg)
    if not isinstance(offset_hz, Real) or not np.isfinite(offset_hz):
        raise ValueError("offset_hz must be a finite scalar")
    time = np.arange(values.shape[0], dtype=np.float32) / np.float32(sample_rate)
    correction = np.exp(
        np.asarray(
            -2j * np.pi * np.float32(offset_hz) * time,
            dtype=np.complex64,
        )
    )[:, None].astype(np.complex64, copy=False)
    corrected = values * correction
    return corrected[:, 0] if was_vector else corrected


def lte_frequency_offset(
    cfg: Mapping[str, Any] | Any,
    waveform: np.ndarray,
    toffset: int | None = None,
    *,
    return_correlation: bool = False,
) -> float | tuple[float, np.ndarray]:
    """Estimate average CFO from cyclic-prefix correlation.

    The estimator forms ``x[n+Nfft] * conj(x[n])`` and averages it over a
    shortest-CP window.  If ``toffset`` is omitted, the strongest correlation
    position is selected; otherwise it is interpreted as a zero-based sample
    index in the returned correlation sequence.  This preserves the useful
    MATLAB control point while keeping the Python indexing explicit.

    The estimate is unambiguous over approximately ``[-Fs/(2*Nfft),
    Fs/(2*Nfft)]``.  Set ``return_correlation=True`` to receive the complex
    per-antenna correlation matrix as ``(offset_hz, correlation)``.
    """

    values, _ = _as_waveform(waveform)
    info = _ofdm_info_from_config(cfg)
    cp_lengths = tuple(
        int(item)
        for item in _field(info, "cyclic_prefix_lengths", "cp_lengths", "CyclicPrefixLengths")
    )
    cp_window = min(cp_lengths)
    lag = int(_field(info, "nfft", "Nfft"))
    if values.shape[0] <= lag + cp_window:
        raise ValueError("waveform is too short for cyclic-prefix correlation")

    product = values[lag:, :] * np.conj(values[:-lag, :])
    prefix = np.vstack((np.zeros((1, values.shape[1]), dtype=product.dtype), np.cumsum(product, axis=0)))
    correlation = prefix[cp_window:] - prefix[:-cp_window]
    if toffset is None:
        position = int(np.argmax(np.max(np.abs(correlation), axis=1)))
    else:
        position = _sample_index(toffset, "toffset")
        if position >= correlation.shape[0]:
            raise ValueError("toffset is outside the correlation sequence")

    selected = np.sum(correlation[position, :])
    if selected == 0:
        offset_hz = 0.0
    else:
        sample_rate = float(
            _field(info, "sampling_rate_hz", "sampling_rate", "SamplingRate")
        )
        offset_hz = float(np.angle(selected) * sample_rate / (2 * np.pi * lag))
    if return_correlation:
        return offset_hz, correlation
    return offset_hz


def _ofdm_info_from_config(cfg: Mapping[str, Any] | Any):
    explicit = _field(
        cfg,
        "ofdm_info",
        "OfdmInfo",
        default=None,
    )
    if explicit is not None:
        return explicit
    ndlrb = _field(cfg, "ndlrb", "NDLRB", "nulrb", "NULRB", default=None)
    if ndlrb is None:
        raise ValueError("cfg must contain NDLRB/NULRB or an explicit OFDM info")
    cp_name = "cyclic_prefix_ul" if _field(cfg, "nulrb", "NULRB", default=None) is not None else "cyclic_prefix"
    cp_matlab_name = "CyclicPrefixUL" if cp_name == "cyclic_prefix_ul" else "CyclicPrefix"
    cp = _field(cfg, cp_name, cp_matlab_name, default="Normal")
    return lte_ofdm_info({"ndlrb": int(ndlrb), "cyclic_prefix": cp})


def _sample_rate(cfg: Mapping[str, Any] | Any) -> float:
    explicit = _field(
        cfg,
        "sampling_rate_hz",
        "sample_rate_hz",
        "sampling_rate",
        "SamplingRate",
        default=None,
    )
    if explicit is not None:
        if not isinstance(explicit, Real) or not np.isfinite(explicit) or explicit <= 0:
            raise ValueError("sampling rate must be positive and finite")
        return float(explicit)
    return float(
        _field(
            _ofdm_info_from_config(cfg),
            "sampling_rate_hz",
            "sampling_rate",
            "SamplingRate",
        )
    )


def _as_waveform(waveform: np.ndarray) -> tuple[np.ndarray, bool]:
    values = np.asarray(waveform)
    was_vector = values.ndim == 1
    if was_vector:
        values = values[:, None]
    if values.ndim != 2 or values.shape[1] == 0:
        raise ValueError("waveform must have shape (samples, antennas)")
    if not np.issubdtype(values.dtype, np.number) or not np.all(np.isfinite(values)):
        raise ValueError("waveform must be finite numeric data")
    return values.astype(np.complex64, copy=False), was_vector


def _sample_index(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be an integer")
    if not np.isfinite(value) or int(value) != value or int(value) < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return int(value)


def _field(value: Mapping[str, Any] | Any, *names: str, default: Any = ...,) -> Any:
    if isinstance(value, Mapping):
        for name in names:
            if name in value:
                return value[name]
    else:
        for name in names:
            if hasattr(value, name):
                return getattr(value, name)
    if default is not ...:
        return default
    raise ValueError(f"Missing LTE field; expected one of {names}")


__all__ = ["lte_frequency_correct", "lte_frequency_offset"]
