"""LTE master information block (MIB) bit-field encoding and decoding."""

from __future__ import annotations

from collections.abc import Mapping
from numbers import Integral, Real
from typing import Any

import numpy as np


_BANDWIDTHS = (6, 15, 25, 50, 75, 100)
_NG_VALUES = ("Sixth", "Half", "One", "Two")


def lte_mib(
    value: Mapping[str, Any] | Any,
    enb: Mapping[str, Any] | Any | None = None,
) -> np.ndarray | dict[str, Any]:
    """Encode an LTE MIB or decode 24 MIB bits into cell settings.

    ``lte_mib(config)`` returns a one-dimensional ``uint8`` array of 24 bits.
    ``lte_mib(bits)`` decodes a bit vector and returns a Python mapping with
    ``ndlrb``, ``phich_duration``, ``ng`` and ``nframe``.  The optional
    ``enb`` argument preserves other configuration fields while replacing
    these decoded values, matching MATLAB's ``lteMIB(mib,enb)`` form.

    The first three bits encode the standard downlink bandwidth table, the
    next bit the PHICH duration, the next two bits the PHICH Ng value, and
    the following eight bits ``floor(NFrame/4)``.  The final ten bits are
    reserved and are encoded as zero.
    """

    if isinstance(value, Mapping) or _looks_like_config(value):
        if enb is not None:
            raise ValueError("enb is only valid when decoding MIB bits")
        return _encode(value)
    bits = _normalise_bits(value)
    decoded = _decode(bits)
    if enb is None:
        return decoded
    result = _mapping_copy(enb)
    for name, decoded_value in decoded.items():
        _replace_field(result, name, decoded_value)
    return result


def _encode(config: Mapping[str, Any] | Any) -> np.ndarray:
    nrb = _integer(_field(config, "ndlrb", "NDLRB", default=0), "NDLRB")
    if nrb in _BANDWIDTHS:
        bandwidth_code = _BANDWIDTHS.index(nrb)
    else:
        bandwidth_code = 7
    duration = str(
        _field(config, "phich_duration", "PHICHDuration", default="Normal")
    ).lower()
    if duration not in {"normal", "extended"}:
        raise ValueError("PHICH duration must be 'Normal' or 'Extended'")
    ng = str(_field(config, "ng", "Ng", default="Sixth")).lower()
    ng_codes = {name.lower(): index for index, name in enumerate(_NG_VALUES)}
    if ng not in ng_codes:
        raise ValueError("Ng must be 'Sixth', 'Half', 'One', or 'Two'")
    frame = _integer(_field(config, "nframe", "NFrame", default=0), "NFrame")
    if frame < 0 or frame > 1023:
        raise ValueError("NFrame must be in [0, 1023]")

    bits = np.zeros(24, dtype=np.uint8)
    bits[:3] = _bits_msb(bandwidth_code, 3)
    bits[3] = duration == "extended"
    bits[4:6] = _bits_msb(ng_codes[ng], 2)
    bits[6:14] = _bits_msb(frame // 4, 8)
    return bits


def _decode(bits: np.ndarray) -> dict[str, Any]:
    bandwidth_code = _from_bits(bits[:3])
    ndlrb = _BANDWIDTHS[bandwidth_code] if bandwidth_code < len(_BANDWIDTHS) else 0
    duration = "Extended" if bits[3] else "Normal"
    ng = _NG_VALUES[_from_bits(bits[4:6])]
    frame = 4 * _from_bits(bits[6:14])
    return {
        "ndlrb": ndlrb,
        "phich_duration": duration,
        "ng": ng,
        "nframe": frame,
    }


def _normalise_bits(value: Any) -> np.ndarray:
    bits = np.asarray(value).reshape(-1)
    if not np.issubdtype(bits.dtype, np.number) or not np.all(np.isfinite(bits)):
        raise TypeError("MIB must contain numeric binary values")
    if np.any((bits != 0) & (bits != 1)):
        raise ValueError("MIB values must be 0 or 1")
    result = np.zeros(24, dtype=np.uint8)
    count = min(24, bits.size)
    result[:count] = bits[:count].astype(np.uint8)
    return result


def _bits_msb(value: int, width: int) -> np.ndarray:
    return np.asarray([(value >> shift) & 1 for shift in range(width - 1, -1, -1)], dtype=np.uint8)


def _from_bits(bits: np.ndarray) -> int:
    result = 0
    for bit in bits:
        result = (result << 1) | int(bit)
    return result


def _looks_like_config(value: Any) -> bool:
    return not isinstance(value, (str, bytes, np.ndarray, list, tuple)) and (
        hasattr(value, "NDLRB") or hasattr(value, "ndlrb")
    )


def _mapping_copy(value: Mapping[str, Any] | Any) -> dict[str, Any]:
    if isinstance(value, Mapping):
        return dict(value)
    return {
        name: getattr(value, name)
        for name in dir(value)
        if not name.startswith("_") and not callable(getattr(value, name))
    }


def _replace_field(result: dict[str, Any], name: str, value: Any) -> None:
    aliases = {
        "ndlrb": ("ndlrb", "NDLRB"),
        "phich_duration": ("phich_duration", "PHICHDuration"),
        "ng": ("ng", "Ng"),
        "nframe": ("nframe", "NFrame"),
    }[name]
    for alias in aliases:
        if alias in result:
            result[alias] = value
            return
    result[aliases[0]] = value


def _field(value: Mapping[str, Any] | Any, *names: str, default: Any = ...) -> Any:
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


def _integer(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be an integer")
    if not np.isfinite(value) or int(value) != value:
        raise ValueError(f"{name} must be an integer")
    return int(value)


__all__ = ["lte_mib"]
