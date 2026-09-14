"""LTE OFDM numerology corresponding to MATLAB ``lteOFDMInfo``."""

from __future__ import annotations

from dataclasses import dataclass
from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np


_DEFAULT_NFFT = {
    6: 128,
    15: 256,
    25: 512,
    50: 1024,
    75: 2048,
    100: 2048,
}
_DEFAULT_WINDOWING = {
    6: 4,
    15: 6,
    25: 4,
    50: 6,
    75: 8,
    100: 8,
}
_NORMAL_CP_2048 = (160, 144, 144, 144, 144, 144, 144, 160, 144, 144, 144, 144, 144, 144)
_EXTENDED_CP_2048 = (512,) * 12


@dataclass(frozen=True)
class LteOfdmInfo:
    """OFDM parameters returned by :func:`lte_ofdm_info`.

    Python-facing fields use snake_case.  ``as_dict`` also exposes the
    MATLAB-compatible names because lock metadata is exchanged at the
    receiver boundary during the migration.
    """

    ndlrb: int
    cyclic_prefix: str
    sampling_rate_hz: float
    nfft: int
    windowing: int
    cyclic_prefix_lengths: tuple[int, ...]

    @property
    def sampling_rate(self) -> float:
        return self.sampling_rate_hz

    @property
    def cp_lengths(self) -> tuple[int, ...]:
        return self.cyclic_prefix_lengths

    @property
    def pss_symbol_index(self) -> int:
        """Zero-based OFDM-symbol index carrying PSS in a subframe."""

        return 6 if self.cyclic_prefix == "Normal" else 5

    @property
    def pss_offset(self) -> int:
        """Samples from a subframe start to the PSS symbol start."""

        return sum(
            self.nfft + cp for cp in self.cyclic_prefix_lengths[: self.pss_symbol_index]
        )

    def as_dict(self) -> dict[str, Any]:
        return {
            "ndlrb": self.ndlrb,
            "cyclic_prefix": self.cyclic_prefix,
            "sampling_rate_hz": self.sampling_rate_hz,
            "nfft": self.nfft,
            "windowing": self.windowing,
            "cyclic_prefix_lengths": self.cyclic_prefix_lengths,
            "NDLRB": self.ndlrb,
            "CyclicPrefix": self.cyclic_prefix,
            "SamplingRate": self.sampling_rate_hz,
            "Nfft": self.nfft,
            "Windowing": self.windowing,
            "CyclicPrefixLengths": self.cyclic_prefix_lengths,
        }


def lte_ofdm_info(
    enb: Mapping[str, Any] | Any,
    nfft: int | None = None,
) -> LteOfdmInfo:
    """Return LTE OFDM information for an eNodeB-style configuration.

    The default FFT-size table and CP scaling follow the local MATLAB
    ``MATLAB_LIB_REFER.md`` reference.  Explicit ``nfft`` values are allowed
    when they are large enough for the active subcarriers and produce integer
    CP lengths, matching the documented MATLAB validation.
    """

    ndlrb = _integer_field(enb, "ndlrb", "NDLRB")
    if ndlrb not in _DEFAULT_NFFT:
        raise ValueError("ndlrb must be one of 6, 15, 25, 50, 75, or 100")

    cyclic_prefix = str(
        _field(enb, "cyclic_prefix", "CyclicPrefix", default="Normal")
    ).lower()
    if cyclic_prefix not in {"normal", "extended"}:
        raise ValueError("cyclic_prefix must be 'Normal' or 'Extended'")
    cyclic_prefix = cyclic_prefix.capitalize()

    default_nfft = _DEFAULT_NFFT[ndlrb]
    selected_nfft = default_nfft if nfft is None else _positive_integer(nfft, "nfft")
    active_subcarriers = ndlrb * 12
    if selected_nfft < active_subcarriers:
        raise ValueError(
            f"nfft ({selected_nfft}) must be at least the active-subcarrier "
            f"count ({active_subcarriers})"
        )

    base_cp = _NORMAL_CP_2048 if cyclic_prefix == "Normal" else _EXTENDED_CP_2048
    cp_scale = selected_nfft / 2048.0
    scaled_cp = tuple(cp * cp_scale for cp in base_cp)
    rounded_cp = tuple(int(round(cp)) for cp in scaled_cp)
    if any(not np.isclose(value, rounded) for value, rounded in zip(scaled_cp, rounded_cp)):
        raise ValueError("nfft produces non-integer cyclic-prefix lengths")

    explicit_windowing = _field(enb, "windowing", "Windowing", default=None)
    if explicit_windowing is None:
        windowing = int(round(_DEFAULT_WINDOWING[ndlrb] * selected_nfft / default_nfft))
    else:
        windowing = _positive_integer(explicit_windowing, "windowing", allow_zero=True)

    return LteOfdmInfo(
        ndlrb=ndlrb,
        cyclic_prefix=cyclic_prefix,
        sampling_rate_hz=selected_nfft * 15_000.0,
        nfft=selected_nfft,
        windowing=windowing,
        cyclic_prefix_lengths=rounded_cp,
    )


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


__all__ = ["LteOfdmInfo", "lte_ofdm_info"]
