"""NumPy implementation of the project's full-band LTE OFDM demodulator.

The LTE-specific calculation of FFT size and cyclic-prefix lengths remains a
separate primitive.  An :class:`OfdmPlan` contains the static work for one
waveform shape so streaming callers do not rebuild symbol positions, phase
corrections, or active-subcarrier maps for every subframe.
"""

from __future__ import annotations

from dataclasses import dataclass
from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from ltesen.ltephy.common.numerology import LteOfdmInfo, lte_ofdm_info


@dataclass(frozen=True)
class OfdmParameters:
    """OFDM parameters required by the demodulator."""

    nfft: int
    sampling_rate_hz: float
    cyclic_prefix_lengths: tuple[int, ...]

    def __post_init__(self) -> None:
        if not isinstance(self.nfft, int) or self.nfft <= 0:
            raise ValueError("nfft must be a positive integer")
        if not np.isfinite(self.sampling_rate_hz) or self.sampling_rate_hz <= 0:
            raise ValueError("sampling_rate_hz must be positive and finite")
        if not self.cyclic_prefix_lengths or any(
            not isinstance(length, int) or length < 0
            for length in self.cyclic_prefix_lengths
        ):
            raise ValueError("cyclic_prefix_lengths must contain non-negative integers")

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any] | Any) -> "OfdmParameters":
        """Read either Python-style or MATLAB-style OFDM metadata."""

        return cls(
            nfft=int(_field(value, "nfft", "Nfft")),
            sampling_rate_hz=float(
                _field(value, "sampling_rate_hz", "sampling_rate", "SamplingRate")
            ),
            cyclic_prefix_lengths=tuple(
                int(item)
                for item in _field(
                    value, "cyclic_prefix_lengths", "CpLengths", "CyclicPrefixLengths"
                )
            ),
        )


@dataclass(frozen=True)
class FullOfdmInfo:
    """Metadata and zero-based index maps returned with a full FFT grid."""

    nfft: int
    sampling_rate_hz: float
    subcarrier_spacing_hz: float
    active_indices: np.ndarray
    dc_index: int
    guard_lower_indices: np.ndarray
    guard_upper_indices: np.ndarray
    cyclic_prefix_lengths: tuple[int, ...]
    cp_fraction: float
    n_sym: int
    symbol_map: np.ndarray

    def as_dict(self) -> dict[str, Any]:
        """Return a serialization-friendly representation."""

        return {
            "nfft": self.nfft,
            "sampling_rate_hz": self.sampling_rate_hz,
            "subcarrier_spacing_hz": self.subcarrier_spacing_hz,
            "active_indices": self.active_indices.copy(),
            "dc_index": self.dc_index,
            "guard_lower_indices": self.guard_lower_indices.copy(),
            "guard_upper_indices": self.guard_upper_indices.copy(),
            "cyclic_prefix_lengths": self.cyclic_prefix_lengths,
            "cp_fraction": self.cp_fraction,
            "n_sym": self.n_sym,
            "symbol_map": self.symbol_map.copy(),
        }


@dataclass(frozen=True)
class OfdmPlan:
    """Static OFDM work products for one waveform length and CP fraction."""

    params: OfdmParameters
    ndlrb: int
    sample_count: int
    cp_fraction: float
    fft_starts: np.ndarray
    symbol_map: np.ndarray
    phase_correction: np.ndarray
    info: FullOfdmInfo


def build_ofdm_plan(
    ofdm: OfdmParameters | Mapping[str, Any] | Any,
    ndlrb: int,
    *,
    cp_fraction: float = 1.0,
    sample_count: int | None = None,
) -> OfdmPlan:
    """Build reusable symbol positions, phase vectors, and bin maps."""

    params = ofdm if isinstance(ofdm, OfdmParameters) else OfdmParameters.from_mapping(ofdm)
    if not isinstance(ndlrb, int) or ndlrb <= 0:
        raise ValueError("ndlrb must be a positive integer")
    if not np.isfinite(cp_fraction) or not 0 <= cp_fraction <= 1:
        raise ValueError("cp_fraction must be between 0 and 1")
    one_subframe = sum(params.nfft + cp for cp in params.cyclic_prefix_lengths)
    target_count = one_subframe if sample_count is None else int(sample_count)
    if target_count <= 0:
        raise ValueError("sample_count must be positive")

    starts: list[int] = []
    symbol_maps: list[int] = []
    position = 0
    symbol_number = 0
    while True:
        symbol_map = symbol_number % len(params.cyclic_prefix_lengths)
        cp_length = params.cyclic_prefix_lengths[symbol_map]
        symbol_length = params.nfft + cp_length
        if position + symbol_length > target_count:
            break
        starts.append(position + int(np.floor(cp_length * cp_fraction)))
        symbol_maps.append(symbol_map)
        position += symbol_length
        symbol_number += 1
    if not starts:
        raise ValueError("waveform is too short for one complete OFDM symbol")

    fft_starts = np.asarray(starts, dtype=np.int64)
    symbol_map = np.asarray(symbol_maps, dtype=np.int64)
    sample_axis = np.arange(params.nfft, dtype=np.float32)
    phase_correction = np.empty(
        (params.nfft, len(starts)), dtype=np.complex64
    )
    for output_index, cp_index in enumerate(symbol_map):
        cp_length = params.cyclic_prefix_lengths[int(cp_index)]
        delta = cp_length - int(np.floor(cp_length * cp_fraction))
        phase_correction[:, output_index] = np.exp(
            np.asarray(
                1j * 2 * np.pi * delta * sample_axis / params.nfft,
                dtype=np.complex64,
            )
        ).astype(np.complex64, copy=False)

    active_count = ndlrb * 12
    if active_count >= params.nfft or active_count % 2:
        raise ValueError("ndlrb produces an invalid active-subcarrier count")
    half_active = active_count // 2
    active_indices = np.concatenate(
        (
            np.arange(params.nfft - half_active, params.nfft),
            np.arange(1, half_active + 1),
        )
    ).astype(np.int64, copy=False)
    guard_lower = np.arange(params.nfft // 2, params.nfft - half_active, dtype=np.int64)
    guard_upper = np.arange(half_active + 1, params.nfft // 2, dtype=np.int64)
    info = FullOfdmInfo(
        nfft=params.nfft,
        sampling_rate_hz=params.sampling_rate_hz,
        subcarrier_spacing_hz=params.sampling_rate_hz / params.nfft,
        active_indices=active_indices,
        dc_index=0,
        guard_lower_indices=guard_lower,
        guard_upper_indices=guard_upper,
        cyclic_prefix_lengths=params.cyclic_prefix_lengths,
        cp_fraction=float(cp_fraction),
        n_sym=len(starts),
        symbol_map=symbol_map,
    )
    return OfdmPlan(
        params=params,
        ndlrb=ndlrb,
        sample_count=target_count,
        cp_fraction=float(cp_fraction),
        fft_starts=fft_starts,
        symbol_map=symbol_map,
        phase_correction=phase_correction,
        info=info,
    )


def demodulate_full(
    waveform: np.ndarray,
    ofdm: OfdmParameters | OfdmPlan | Mapping[str, Any] | Any,
    ndlrb: int,
    cp_fraction: float = 1.0,
    *,
    plan: OfdmPlan | None = None,
) -> tuple[np.ndarray, FullOfdmInfo]:
    """Demodulate every complete OFDM symbol and retain all FFT bins.

    When ``plan`` is supplied, symbol positions, phase correction, and bin
    maps are reused.  The time-domain symbols are gathered into one array and
    transformed by one batched FFT call, reducing Python-to-NumPy call
    overhead while preserving the previous output layout.
    """

    samples = np.asarray(waveform)
    if samples.ndim == 1:
        samples = samples[:, None]
    if samples.ndim != 2:
        raise ValueError("waveform must have shape (samples, antennas)")
    if not np.issubdtype(samples.dtype, np.number):
        raise TypeError("waveform must be numeric")
    if not np.all(np.isfinite(samples)):
        raise ValueError("waveform must contain only finite values")
    samples = samples.astype(np.complex64, copy=False)

    if plan is None:
        if isinstance(ofdm, OfdmPlan):
            plan = ofdm
        else:
            plan = build_ofdm_plan(
                ofdm,
                ndlrb,
                cp_fraction=cp_fraction,
                sample_count=samples.shape[0],
            )
    if plan.ndlrb != ndlrb:
        raise ValueError("OFDM plan does not match ndlrb")
    if plan.sample_count != samples.shape[0]:
        raise ValueError(
            "OFDM plan sample_count does not match waveform length; "
            "build a plan for this waveform shape"
        )
    if not np.isclose(plan.cp_fraction, cp_fraction):
        raise ValueError("OFDM plan cp_fraction does not match the requested value")

    n_rx = samples.shape[1]
    time_symbols = np.empty(
        (plan.params.nfft, plan.info.n_sym, n_rx), dtype=np.complex64
    )
    for output_index, fft_start in enumerate(plan.fft_starts):
        time_symbols[:, output_index, :] = samples[
            int(fft_start) : int(fft_start) + plan.params.nfft, :
        ]
    spectrum = np.fft.fft(time_symbols, axis=0)
    grid = (
        spectrum
        * plan.phase_correction[:, :, None]
        / np.float32(np.sqrt(plan.params.nfft))
    ).astype(np.complex64, copy=False)
    return grid, plan.info


def lte_ofdm_demodulate(
    enb: Mapping[str, Any] | Any,
    waveform: np.ndarray,
    cp_fraction: float | None = 0.55,
    nfft: int | None = None,
    *,
    plan: OfdmPlan | None = None,
) -> np.ndarray:
    """Demodulate a time-domain LTE waveform into its active resource grid."""

    if cp_fraction is None:
        cp_fraction = 0.55
    ndlrb = _integer_field(enb, "ndlrb", "NDLRB")
    ofdm_info = lte_ofdm_info(enb, nfft=nfft) if plan is None else plan.params
    full_grid, full_info = demodulate_full(
        waveform,
        plan.params if plan is not None else ofdm_info.as_dict(),
        ndlrb=ndlrb,
        cp_fraction=cp_fraction,
        plan=plan,
    )
    active_grid = full_grid[full_info.active_indices, :, :]
    return (active_grid * np.float32(np.sqrt(ofdm_info.nfft))).astype(
        np.complex64, copy=False
    )


def _field(
    value: Mapping[str, Any] | Any,
    *names: str,
    default: Any = ...,
) -> Any:
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
    raise ValueError(f"Missing OFDM field; expected one of {names}")


def _integer_field(value: Mapping[str, Any] | Any, *names: str) -> int:
    return _positive_integer(_field(value, *names), names[0])


def _positive_integer(value: Any, name: str, *, allow_zero: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be an integer")
    if not np.isfinite(value) or int(value) != value:
        raise ValueError(f"{name} must be an integer")
    integer = int(value)
    if integer < 0 or (integer == 0 and not allow_zero):
        qualifier = "non-negative" if allow_zero else "positive"
        raise ValueError(f"{name} must be {qualifier}")
    return integer


__all__ = [
    "FullOfdmInfo",
    "LteOfdmInfo",
    "OfdmParameters",
    "OfdmPlan",
    "build_ofdm_plan",
    "demodulate_full",
    "lte_ofdm_demodulate",
    "lte_ofdm_info",
]
