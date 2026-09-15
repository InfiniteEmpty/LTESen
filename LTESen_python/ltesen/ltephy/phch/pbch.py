"""LTE PBCH scrambling, modulation, and resource-element mapping."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping, Sequence

import numpy as np

from ltesen.ltephy.common import lte_gold_sequence


def lte_pbch_prbs(
    enb: Mapping[str, Any] | Any,
    length: int | Sequence[int],
    mapping: str = "binary",
) -> np.ndarray:
    """Generate the LTE PBCH scrambling sequence.

    ``length`` is either an integer number of values or ``(start, count)``
    using a zero-based start, matching MATLAB's ``ltePBCHPRBS``.  The Gold
    generator is initialized with ``NCellID``.  ``mapping='binary'`` returns
    0/1 values; ``mapping='signed'`` returns +1/-1 values.
    """

    cell_id = _field(enb, "ncellid", "NCellID")
    if isinstance(cell_id, bool) or not isinstance(cell_id, (Integral, Real)):
        raise ValueError("NCellID must be an integer")
    cell_id = int(cell_id)
    if not 0 <= cell_id <= 503:
        raise ValueError("NCellID must be in [0, 503]")
    if isinstance(length, (Integral, Real)) and not isinstance(length, bool):
        start, count = 0, _nonnegative_integer(length, "length")
    else:
        values = tuple(length)
        if len(values) != 2:
            raise ValueError("length must be an integer or a (start, count) pair")
        start = _nonnegative_integer(values[0], "start")
        count = _nonnegative_integer(values[1], "count")
    sequence = lte_gold_sequence(cell_id, start + count)[start:]
    mode = str(mapping).lower()
    if mode == "binary":
        return sequence.astype(np.uint8)
    if mode == "signed":
        return (1 - 2 * sequence).astype(np.int8)
    raise ValueError("mapping must be 'binary' or 'signed'")


def lte_pbch(
    enb: Mapping[str, Any] | Any,
    codeword: Any,
    frame_mod4: int = 0,
) -> np.ndarray:
    """Create one PBCH frame's QPSK symbols from a BCH codeword.

    ``codeword`` may be one quarter of a BCH codeword (480 bits for normal CP
    or 432 bits for extended CP), or the complete 40 ms codeword.  In the
    latter form ``frame_mod4`` selects the quarter transmitted by this frame.
    The output has shape ``(N_RE, CellRefP)`` and follows the LTE PBCH
    scrambling, QPSK, layer-mapping and transmit-diversity conventions.
    """

    values = _normalise_bits(codeword)
    quarter = 216 * 2 if _prefix(enb) == "extended" else 240 * 2
    period = 4 * quarter
    frame = _nonnegative_integer(frame_mod4, "frame_mod4")
    if frame > 3:
        raise ValueError("frame_mod4 must be in [0, 3]")
    if values.size == period:
        values = values[frame * quarter : (frame + 1) * quarter]
    elif values.size != quarter:
        raise ValueError(
            f"codeword must contain {quarter} bits or the full {period}-bit BCH codeword"
        )

    scrambled = values ^ lte_pbch_prbs(
        enb, (frame * quarter, values.size), mapping="binary"
    )
    symbols = (
        (1.0 - 2.0 * scrambled[0::2].astype(np.float64))
        + 1j * (1.0 - 2.0 * scrambled[1::2].astype(np.float64))
    ) / np.sqrt(2.0)

    ports = _bounded_integer(
        _field(enb, "cell_ref_p", "CellRefP", default=1), "CellRefP", 1, 4
    )
    if ports not in {1, 2, 4}:
        raise ValueError("CellRefP must be one of 1, 2, or 4")
    if ports == 1:
        return symbols[:, None]

    if ports == 2:
        if symbols.size % 2:
            raise ValueError("two-port PBCH requires an even symbol count")
        layers = symbols.reshape(-1, 2)
        output = np.zeros((symbols.size, 2), dtype=np.complex128)
        scale = 1.0 / np.sqrt(2.0)
        output[0::2, 0] = layers[:, 0] * scale
        output[1::2, 0] = layers[:, 1] * scale
        output[0::2, 1] = -np.conj(layers[:, 1]) * scale
        output[1::2, 1] = np.conj(layers[:, 0]) * scale
        return output

    if symbols.size % 4:
        raise ValueError("four-port PBCH requires a symbol count divisible by four")
    layers = symbols.reshape(-1, 4)
    output = np.zeros((symbols.size, 4), dtype=np.complex128)
    scale = 1.0 / np.sqrt(2.0)
    output[0::4, 0] = layers[:, 0] * scale
    output[1::4, 0] = layers[:, 1] * scale
    output[2::4, 1] = layers[:, 2] * scale
    output[3::4, 1] = layers[:, 3] * scale
    output[0::4, 2] = -np.conj(layers[:, 1]) * scale
    output[1::4, 2] = np.conj(layers[:, 0]) * scale
    output[2::4, 3] = -np.conj(layers[:, 3]) * scale
    output[3::4, 3] = np.conj(layers[:, 2]) * scale
    return output


def lte_pbch_indices(
    enb: Mapping[str, Any] | Any,
    options: str | Sequence[str] | None = None,
) -> np.ndarray:
    """Return PBCH resource locations for a one-subframe resource grid."""

    rb_count = _bounded_integer(_field(enb, "ndlrb", "NDLRB"), "NDLRB", 6, 110)
    cell_id = _bounded_integer(
        _field(enb, "ncellid", "NCellID"), "NCellID", 0, 503
    )
    ports = _bounded_integer(
        _field(enb, "cell_ref_p", "CellRefP", default=1), "CellRefP", 1, 4
    )
    if ports not in {1, 2, 4}:
        raise ValueError("CellRefP must be one of 1, 2, or 4")
    n_subframe = _bounded_integer(
        _field(enb, "nsubframe", "NSubframe", default=0), "NSubframe", 0, 9
    )
    style, base = _parse_index_options(options)
    n_symbols = 14 if _prefix(enb) == "normal" else 12
    if n_subframe != 0:
        shape = (0, 3) if style == "sub" else (0, ports)
        return np.empty(shape, dtype=np.uint32)

    first_symbol = 7 if n_symbols == 14 else 6
    center_start = 6 * (rb_count - 6)
    v_shift = cell_id % 6
    rows: list[tuple[int, int, int]] = []
    for port in range(ports):
        for symbol_offset in range(4):
            symbol = first_symbol + symbol_offset
            reserve = symbol_offset in (
                {0, 1} if n_symbols == 14 else {0, 1, 3}
            )
            for local_subcarrier in range(72):
                if reserve and (local_subcarrier - v_shift) % 3 == 0:
                    continue
                rows.append((center_start + local_subcarrier, symbol, port))

    subs = np.asarray(rows, dtype=np.int64)
    if base == 1:
        subs = subs + 1
    if style == "sub":
        return subs.astype(np.uint32)

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


def _nonnegative_integer(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be a non-negative integer")
    if not np.isfinite(value) or int(value) != value or int(value) < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return int(value)


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
    raise ValueError(f"Missing LTE field; expected one of {names}")


def _prefix(value: Mapping[str, Any] | Any) -> str:
    prefix = str(
        _field(value, "cyclic_prefix", "CyclicPrefix", default="Normal")
    ).lower()
    if prefix not in {"normal", "extended"}:
        raise ValueError("CyclicPrefix must be 'Normal' or 'Extended'")
    return prefix


def _normalise_bits(value: Any) -> np.ndarray:
    values = np.asarray(value).reshape(-1)
    if not np.issubdtype(values.dtype, np.number):
        raise TypeError("codeword must contain numeric binary values")
    if values.size and (not np.all(np.isfinite(values)) or np.any((values != 0) & (values != 1))):
        raise ValueError("codeword must contain only 0 and 1")
    return values.astype(np.uint8, copy=False)


def _bounded_integer(value: Any, name: str, lower: int, upper: int) -> int:
    integer = _nonnegative_integer(value, name)
    if integer < lower or integer > upper:
        raise ValueError(f"{name} must be in [{lower}, {upper}]")
    return integer


def _parse_index_options(
    options: str | Sequence[str] | None,
) -> tuple[str, int]:
    if options is None:
        return "sub", 0
    tokens = (
        options.lower().split()
        if isinstance(options, str)
        else [str(item).lower() for item in options]
    )
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


__all__ = ["lte_pbch", "lte_pbch_indices", "lte_pbch_prbs"]
