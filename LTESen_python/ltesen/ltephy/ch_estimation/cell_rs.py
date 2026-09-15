"""LTE cell-specific reference signal (CRS) indices and symbols."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping, Sequence

import numpy as np

from ltesen.ltephy.common import lte_gold_sequence


_NORMAL_CRS = {
    0: ((0, 0), (4, 3), (7, 0), (11, 3)),
    1: ((0, 3), (4, 0), (7, 3), (11, 0)),
    2: ((1, 0), (8, 3)),
    3: ((1, 3), (8, 0)),
}
_EXTENDED_CRS = {
    0: ((0, 0), (3, 3), (6, 0), (9, 3)),
    1: ((0, 3), (3, 0), (6, 3), (9, 0)),
    2: ((1, 0), (7, 3)),
    3: ((1, 3), (7, 0)),
}

_MAX_DOWNLINK_RB = 110


def lte_cell_rs_indices(
    enb: Mapping[str, Any] | Any,
    ports: int | Sequence[int] | None = None,
    options: str | Sequence[str] | None = None,
) -> np.ndarray:
    """Return CRS locations for the requested antenna ports.

    Python defaults are zero-based ``(subcarrier, symbol, port)`` rows.  Set
    ``options`` to ``"ind"`` for linear indices or ``"1based"`` to shift the
    returned subscript/linear values by one.  The option tokens ``sub``,
    ``ind``, ``0based`` and ``1based`` may be combined like MATLAB's options.
    """

    rb_count = _bounded_integer(_field(enb, "ndlrb", "NDLRB"), "ndlrb", 6, 110)
    cell_id = _bounded_integer(_field(enb, "ncellid", "NCellID"), "ncellid", 0, 503)
    prefix = _prefix(enb)
    duplex = str(_field(enb, "duplex_mode", "DuplexMode", default="FDD")).lower()
    if duplex != "fdd":
        raise NotImplementedError("CRS indexing currently supports FDD only")
    selected_ports = _ports(enb, ports)
    style, base = _parse_options(options)
    n_symbols = 14 if prefix == "normal" else 12
    mapping = _NORMAL_CRS if prefix == "normal" else _EXTENDED_CRS
    n_subcarriers = 12 * rb_count
    rows: list[tuple[int, int, int]] = []
    v_shift = cell_id % 6
    for port in selected_ports:
        for symbol, v in mapping[port]:
            for m in range(2 * rb_count):
                subcarrier = 6 * m + (v_shift + v) % 6
                rows.append((subcarrier, symbol, port))
    subs = np.asarray(rows, dtype=np.int64)
    if base == 1:
        subs = subs + 1
    if style == "sub":
        return subs.astype(np.uint32)
    linear = (
        (subs[:, 0] - base)
        + n_subcarriers * (subs[:, 1] - base)
        + n_subcarriers * n_symbols * (subs[:, 2] - base)
        + base
    )
    return linear.astype(np.uint32)


def lte_cell_rs(
    enb: Mapping[str, Any] | Any,
    ports: int | Sequence[int] | None = None,
) -> np.ndarray:
    """Return concatenated QPSK CRS symbols for the requested ports."""

    rb_count = _bounded_integer(_field(enb, "ndlrb", "NDLRB"), "ndlrb", 6, 110)
    cell_id = _bounded_integer(_field(enb, "ncellid", "NCellID"), "ncellid", 0, 503)
    n_subframe = _bounded_integer(
        _field(enb, "nsubframe", "NSubframe", default=0), "nsubframe", 0, 9
    )
    prefix = _prefix(enb)
    duplex = str(_field(enb, "duplex_mode", "DuplexMode", default="FDD")).lower()
    if duplex != "fdd":
        raise NotImplementedError("CRS generation currently supports FDD only")
    selected_ports = _ports(enb, ports)
    symbols_per_slot = 7 if prefix == "normal" else 6
    mapping = _NORMAL_CRS if prefix == "normal" else _EXTENDED_CRS
    # TS 36.211 uses N_CP=1 for normal CP and N_CP=0 for extended CP.
    n_cp = 1 if prefix == "normal" else 0
    generated: list[np.ndarray] = []
    for port in selected_ports:
        # Generate one sequence for each CRS OFDM symbol in this port's
        # schedule. Ports 2/3 use different local OFDM symbols than ports
        # 0/1, so their c_init values are correspondingly different.
        for global_symbol, _ in mapping[port]:
            slot = global_symbol // symbols_per_slot
            local_symbol = global_symbol % symbols_per_slot
            n_s = 2 * n_subframe + slot
            c_init = (
                (2**10) * (7 * (n_s + 1) + local_symbol + 1) * (2 * cell_id + 1)
                + 2 * cell_id
                + n_cp
            )
            # The CRS sequence is defined for the maximum downlink bandwidth
            # (110 RB).  A narrower configured carrier takes its centered
            # portion, rather than restarting the sequence at m=0.
            sequence_bits = lte_gold_sequence(c_init, 4 * _MAX_DOWNLINK_RB)
            start = 2 * (_MAX_DOWNLINK_RB - rb_count)
            bits = sequence_bits[start : start + 4 * rb_count]
            generated.append(
                (
                    (1 - 2 * bits[0::2])
                    + np.complex64(1j) * (1 - 2 * bits[1::2])
                ).astype(np.complex64)
                / np.float32(np.sqrt(2))
            )
    return np.concatenate(generated).astype(np.complex64, copy=False) if generated else np.empty(0, dtype=np.complex64)


def _ports(enb: Mapping[str, Any] | Any, ports: int | Sequence[int] | None) -> tuple[int, ...]:
    if ports is None:
        count = _field(enb, "cell_ref_p", "CellRefP")
        count = _integer(count, "CellRefP")
        if count not in {1, 2, 4}:
            raise ValueError("CellRefP must be one of 1, 2, or 4")
        return tuple(range(count))
    if isinstance(ports, (Integral, Real)) and not isinstance(ports, bool):
        values = (int(ports),)
    else:
        values = tuple(_integer(item, "ports") for item in ports)
    if not values or any(port not in {0, 1, 2, 3} for port in values):
        raise ValueError("ports must contain values in [0, 3]")
    return values


def _parse_options(options: str | Sequence[str] | None) -> tuple[str, int]:
    if options is None:
        return "sub", 0
    if isinstance(options, str):
        tokens = options.lower().split()
    else:
        tokens = [str(item).lower() for item in options]
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
            raise ValueError(f"unsupported CRS index option: {token}")
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


__all__ = ["lte_cell_rs", "lte_cell_rs_indices"]
