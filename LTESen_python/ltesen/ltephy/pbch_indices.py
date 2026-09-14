"""LTE physical broadcast channel resource-element indices."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping, Sequence

import numpy as np


def lte_pbch_indices(
    enb: Mapping[str, Any] | Any,
    options: str | Sequence[str] | None = None,
) -> np.ndarray:
    """Return PBCH resource locations for a one-subframe resource grid.

    The Python default is a zero-based ``(subcarrier, symbol, port)`` array,
    with one block of rows per configured CRS port.  ``"ind"`` returns the
    MATLAB-compatible linear-index matrix with shape ``(N, CellRefP)``;
    ``"1based"`` changes the index origin.  PBCH is present only when
    ``NSubframe`` is zero, so other subframes return an empty index array.
    """

    rb_count = _bounded_integer(_field(enb, "ndlrb", "NDLRB"), "NDLRB", 6, 110)
    cell_id = _bounded_integer(_field(enb, "ncellid", "NCellID"), "NCellID", 0, 503)
    ports = _bounded_integer(
        _field(enb, "cell_ref_p", "CellRefP", default=1), "CellRefP", 1, 4
    )
    if ports not in {1, 2, 4}:
        raise ValueError("CellRefP must be one of 1, 2, or 4")
    n_subframe = _bounded_integer(
        _field(enb, "nsubframe", "NSubframe", default=0), "NSubframe", 0, 9
    )
    style, base = _parse_options(options)
    n_symbols = 14 if _prefix(enb) == "normal" else 12
    if n_subframe != 0:
        if style == "sub":
            return np.empty((0, 3), dtype=np.uint32)
        return np.empty((0, ports), dtype=np.uint32)

    first_symbol = 7 if n_symbols == 14 else 6
    center_start = 6 * (rb_count - 6)
    v_shift = cell_id % 6
    rows: list[tuple[int, int, int]] = []
    for port in range(ports):
        for symbol_offset in range(4):
            symbol = first_symbol + symbol_offset
            # PBCH reserves every third RE in the first two symbols for the
            # union of the CRS locations of ports 0..3.  With extended CP,
            # the fourth symbol also overlaps the port-0/1 CRS locations.
            reserve = symbol_offset in ({0, 1} if n_symbols == 14 else {0, 1, 3})
            for local_subcarrier in range(72):
                if reserve and (local_subcarrier - v_shift) % 3 == 0:
                    continue
                rows.append((center_start + local_subcarrier, symbol, port))

    subs = np.asarray(rows, dtype=np.int64)
    if base == 1:
        subs = subs + 1
    if style == "sub":
        return subs.astype(np.uint32)

    # MATLAB's PBCH linear form has one column per port and each column is
    # addressed against the corresponding M-by-N plane.
    per_port = subs.reshape(ports, -1, 3)
    linear = np.empty((per_port.shape[1], ports), dtype=np.int64)
    for port in range(ports):
        current = per_port[port]
        linear[:, port] = (
            (current[:, 0] - base)
            + (rb_count * 12) * (current[:, 1] - base)
            + (rb_count * 12) * n_symbols * port
            + base
        )
    return linear.astype(np.uint32)


def _parse_options(options: str | Sequence[str] | None) -> tuple[str, int]:
    if options is None:
        return "sub", 0
    tokens = options.lower().split() if isinstance(options, str) else [str(x).lower() for x in options]
    style = "sub"
    base = 0
    for token in tokens:
        if token in {"sub", "ind"}:
            style = token
        elif token == "0based":
            base = 0
        elif token == "1based":
            base = 1
        else:
            raise ValueError(f"unsupported PBCH index option: {token}")
    return style, base


def _prefix(value: Mapping[str, Any] | Any) -> str:
    prefix = str(_field(value, "cyclic_prefix", "CyclicPrefix", default="Normal")).lower()
    if prefix not in {"normal", "extended"}:
        raise ValueError("cyclic_prefix must be 'Normal' or 'Extended'")
    return prefix


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


__all__ = ["lte_pbch_indices"]
