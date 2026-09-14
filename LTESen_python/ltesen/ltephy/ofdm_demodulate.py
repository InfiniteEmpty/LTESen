"""LTE active-subcarrier OFDM demodulation."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from ..ltetracking.ofdm import demodulate_full
from .ofdm_info import lte_ofdm_info


def lte_ofdm_demodulate(
    enb: Mapping[str, Any] | Any,
    waveform: np.ndarray,
    cp_fraction: float | None = 0.55,
    nfft: int | None = None,
) -> np.ndarray:
    """Demodulate a time-domain LTE waveform into its active resource grid.

    The waveform must start at the cyclic prefix of an OFDM symbol and have
    the sampling rate implied by ``enb``.  The result has shape
    ``(NDLRB * 12, symbols, receive_antennas)``.  Active subcarriers are in
    native FFT order: negative-frequency bins first, then positive-frequency
    bins, with DC omitted.

    ``cp_fraction`` selects the FFT window inside the cyclic prefix.  The
    MATLAB toolbox default is 0.55; ``1.0`` places the window at the end of
    the prefix.  ``nfft`` is the optional explicit FFT size introduced by
    newer MATLAB releases.

    The project full-grid helper uses power-preserving ``1/sqrt(Nfft)``
    scaling.  MATLAB ``lteOFDMDemodulate`` returns the corresponding
    unscaled FFT values, so this wrapper restores that toolbox convention
    after extracting the active bins.
    """

    if cp_fraction is None:
        cp_fraction = 0.55
    ndlrb = _integer_field(enb, "ndlrb", "NDLRB")
    ofdm_info = lte_ofdm_info(enb, nfft=nfft)
    full_grid, full_info = demodulate_full(
        waveform,
        ofdm_info.as_dict(),
        ndlrb=ndlrb,
        cp_fraction=cp_fraction,
    )
    active_grid = full_grid[full_info.active_indices, :, :]
    return active_grid * np.sqrt(ofdm_info.nfft)


def _integer_field(value: Mapping[str, Any] | Any, *names: str) -> int:
    raw = _field(value, *names)
    if isinstance(raw, bool) or not isinstance(raw, (Integral, Real)):
        raise ValueError(f"{names[0]} must be an integer")
    if not np.isfinite(raw) or int(raw) != raw:
        raise ValueError(f"{names[0]} must be an integer")
    return int(raw)


def _field(value: Mapping[str, Any] | Any, *names: str) -> Any:
    if isinstance(value, Mapping):
        for name in names:
            if name in value:
                return value[name]
    else:
        for name in names:
            if hasattr(value, name):
                return getattr(value, name)
    raise ValueError(f"Missing LTE field; expected one of {names}")


__all__ = ["lte_ofdm_demodulate"]
