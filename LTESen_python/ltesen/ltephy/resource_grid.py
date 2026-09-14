"""LTE downlink and uplink resource-grid dimensions."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np


def lte_resource_grid_size(
    cfg: Mapping[str, Any] | Any,
    antenna_planes: int | None = None,
) -> tuple[int, int, int]:
    """Return ``(subcarriers, symbols, antenna_planes)`` for one subframe.

    A downlink configuration is selected when ``NDLRB`` is present; when it
    is absent, ``NULRB`` selects the uplink form.  This follows MATLAB's
    precedence rule while using a zero-based, tuple-based Python result.
    """

    ndlrb = _field(cfg, "ndlrb", "NDLRB", default=None)
    if ndlrb is not None:
        rb_count = _bounded_integer(ndlrb, "ndlrb", 6, 110)
        prefix = _prefix(cfg, "cyclic_prefix", "CyclicPrefix")
        default_planes = _field(cfg, "cell_ref_p", "CellRefP", default=None)
        planes = _planes(antenna_planes, default_planes, "CellRefP", allowed={1, 2, 4})
    else:
        nulrb = _field(cfg, "nulrb", "NULRB")
        rb_count = _bounded_integer(nulrb, "nulrb", 6, 110)
        prefix = _prefix(cfg, "cyclic_prefix_ul", "CyclicPrefixUL")
        default_planes = _field(cfg, "tx_antennas", "NTxAnts", default=1)
        planes = _planes(antenna_planes, default_planes, "NTxAnts", allowed={1, 2, 4})
    symbols = 14 if prefix == "normal" else 12
    return 12 * rb_count, symbols, planes


def _prefix(value: Mapping[str, Any] | Any, *names: str) -> str:
    raw = _field(value, *names, default="Normal")
    prefix = str(raw).lower()
    if prefix not in {"normal", "extended"}:
        raise ValueError("cyclic prefix must be 'Normal' or 'Extended'")
    return prefix


def _planes(
    explicit: Any,
    configured: Any,
    name: str,
    *,
    allowed: set[int],
) -> int:
    value = configured if explicit is None else explicit
    if value is None:
        raise ValueError(f"configuration must contain {name} when antenna_planes is omitted")
    integer = _integer(value, "antenna_planes" if explicit is not None else name)
    if explicit is not None:
        if integer < 1:
            raise ValueError("antenna_planes must be a positive integer")
        return integer
    if integer not in allowed:
        raise ValueError(f"{name} must be one of {sorted(allowed)}")
    return integer


def _bounded_integer(value: Any, name: str, lower: int, upper: int) -> int:
    integer = _integer(value, name)
    if not lower <= integer <= upper:
        raise ValueError(f"{name} must be in [{lower}, {upper}]")
    return integer


def _integer(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be an integer")
    if not np.isfinite(value) or int(value) != value:
        raise ValueError(f"{name} must be an integer")
    return int(value)


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


__all__ = ["lte_resource_grid_size"]
