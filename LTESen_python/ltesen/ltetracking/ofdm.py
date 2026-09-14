"""NumPy implementation of the project's full-band LTE OFDM demodulator.

The LTE-specific calculation of FFT size and cyclic-prefix lengths remains a
separate primitive.  This module deliberately receives those values
explicitly, so it can be tested without pretending to replace the MATLAB LTE
Toolbox cell configuration functions.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping

import numpy as np


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


def demodulate_full(
    waveform: np.ndarray,
    ofdm: OfdmParameters | Mapping[str, Any] | Any,
    ndlrb: int,
    cp_fraction: float = 1.0,
) -> tuple[np.ndarray, FullOfdmInfo]:
    """Demodulate every complete OFDM symbol and retain all FFT bins.

    Parameters use Python conventions: ``waveform`` is shaped
    ``(samples, receive_antennas)`` (a one-dimensional waveform is accepted),
    and all returned index arrays are zero-based.  The FFT scaling and
    ``cp_fraction`` phase correction match the project's MATLAB helper.
    """

    params = (
        ofdm if isinstance(ofdm, OfdmParameters) else OfdmParameters.from_mapping(ofdm)
    )
    if not isinstance(ndlrb, int) or ndlrb <= 0:
        raise ValueError("ndlrb must be a positive integer")
    if not np.isfinite(cp_fraction) or not 0 <= cp_fraction <= 1:
        raise ValueError("cp_fraction must be between 0 and 1")

    samples = np.asarray(waveform)
    if samples.ndim == 1:
        samples = samples[:, None]
    if samples.ndim != 2:
        raise ValueError("waveform must have shape (samples, antennas)")
    if not np.issubdtype(samples.dtype, np.number):
        raise TypeError("waveform must be numeric")
    if not np.all(np.isfinite(samples)):
        raise ValueError("waveform must contain only finite values")

    n_rx = samples.shape[1]
    cp_lengths = params.cyclic_prefix_lengths
    symbol_positions: list[tuple[int, int, int]] = []
    position = 0
    symbol_number = 0
    while True:
        cp_length = cp_lengths[symbol_number % len(cp_lengths)]
        symbol_length = params.nfft + cp_length
        if position + symbol_length > samples.shape[0]:
            break
        fft_start = position + int(np.floor(cp_length * cp_fraction))
        symbol_positions.append((fft_start, cp_length, symbol_number % len(cp_lengths)))
        position += symbol_length
        symbol_number += 1

    grid = np.empty((params.nfft, len(symbol_positions), n_rx), dtype=np.complex128)
    for output_index, (fft_start, cp_length, symbol_map) in enumerate(symbol_positions):
        del cp_length  # The complete symbol length was consumed above.
        delta = cp_lengths[symbol_map] - int(
            np.floor(cp_lengths[symbol_map] * cp_fraction)
        )
        phase_correction = np.exp(
            1j * 2 * np.pi * delta * np.arange(params.nfft) / params.nfft
        )
        data = samples[fft_start : fft_start + params.nfft, :]
        grid[:, output_index, :] = (
            np.fft.fft(data, axis=0) * phase_correction[:, None] / np.sqrt(params.nfft)
        )

    active_count = ndlrb * 12
    if active_count >= params.nfft or active_count % 2:
        raise ValueError("ndlrb produces an invalid active-subcarrier count")
    half_active = active_count // 2
    active_indices = np.concatenate(
        (np.arange(params.nfft - half_active, params.nfft), np.arange(1, half_active + 1))
    )
    guard_lower = np.arange(params.nfft // 2, params.nfft - half_active)
    guard_upper = np.arange(half_active + 1, params.nfft // 2)
    symbol_map = np.asarray([item[2] for item in symbol_positions], dtype=np.int64)
    info = FullOfdmInfo(
        nfft=params.nfft,
        sampling_rate_hz=params.sampling_rate_hz,
        subcarrier_spacing_hz=params.sampling_rate_hz / params.nfft,
        active_indices=active_indices.astype(np.int64),
        dc_index=0,
        guard_lower_indices=guard_lower.astype(np.int64),
        guard_upper_indices=guard_upper.astype(np.int64),
        cyclic_prefix_lengths=cp_lengths,
        cp_fraction=float(cp_fraction),
        n_sym=len(symbol_positions),
        symbol_map=symbol_map,
    )
    return grid, info


def _field(value: Mapping[str, Any] | Any, *names: str) -> Any:
    if isinstance(value, Mapping):
        for name in names:
            if name in value:
                return value[name]
    else:
        for name in names:
            if hasattr(value, name):
                return getattr(value, name)
    raise ValueError(f"Missing OFDM field; expected one of {names}")


__all__ = ["FullOfdmInfo", "OfdmParameters", "demodulate_full"]
