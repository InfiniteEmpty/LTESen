"""LTE resource-grid dimensions and generic resource extraction."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping, Sequence

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


def lte_extract_resources(
    indices: np.ndarray,
    *grids: np.ndarray,
    options: str | Sequence[str] | None = None,
    return_indices: bool = False,
) -> np.ndarray | tuple[np.ndarray, ...] | tuple[object, object]:
    """Extract resource elements from one or more resource grids.

    ``indices`` may contain linear indices or ``(subcarrier, symbol, port)``
    rows. By default, time-frequency positions are projected over every
    receive/port plane in each input grid.
    """

    if not grids:
        raise ValueError("at least one resource grid is required")
    style, base, method = _parse_options(indices, options)
    positions = _to_subscripts(
        indices,
        style=style,
        base=base,
        grid=np.asarray(grids[0]),
    )
    if method == "allplanes":
        positions = _stable_unique(positions[:, :2])
    outputs = tuple(
        _extract_grid(np.asarray(grid), positions, method) for grid in grids
    )
    result: np.ndarray | tuple[np.ndarray, ...] = (
        outputs[0] if len(outputs) == 1 else outputs
    )
    if not return_indices:
        return result
    return result, positions.copy()


def _extract_grid(
    grid: np.ndarray,
    positions: np.ndarray,
    method: str,
) -> np.ndarray:
    if grid.ndim not in {2, 3, 4}:
        raise ValueError("resource grids must be 2-D, 3-D, or 4-D arrays")
    if np.any(positions[:, 0] < 0) or np.any(positions[:, 0] >= grid.shape[0]):
        raise IndexError("resource subcarrier index is outside the grid")
    if np.any(positions[:, 1] < 0) or np.any(positions[:, 1] >= grid.shape[1]):
        raise IndexError("resource symbol index is outside the grid")

    if method == "allplanes":
        values = grid[positions[:, 0], positions[:, 1]]
        if grid.ndim == 2:
            return values
        if grid.ndim == 3:
            return values.reshape((positions.shape[0], grid.shape[2]))
        return values.reshape((positions.shape[0], grid.shape[2], grid.shape[3]))

    if positions.shape[1] < 3:
        raise ValueError("direct extraction requires a port in each subscript")
    port = positions[:, 2]
    if grid.ndim == 3:
        if np.any(port < 0) or np.any(port >= grid.shape[2]):
            raise IndexError("direct resource plane is outside the grid")
        return grid[positions[:, 0], positions[:, 1], port]
    if grid.ndim == 4:
        if np.any(port < 0) or np.any(port >= grid.shape[3]):
            raise IndexError("direct resource fourth-dimension plane is outside the grid")
        return grid[positions[:, 0], positions[:, 1], :, port]
    return grid[positions[:, 0], positions[:, 1], port]


def _to_subscripts(
    indices: np.ndarray,
    *,
    style: str,
    base: int,
    grid: np.ndarray,
) -> np.ndarray:
    raw = np.asarray(indices)
    if not np.issubdtype(raw.dtype, np.number):
        raise TypeError("indices must be numeric")
    if not np.all(np.isfinite(raw)) or np.any(raw != np.floor(raw)):
        raise ValueError("indices must contain finite integers")
    raw = raw.astype(np.int64, copy=False)

    if style == "sub":
        if raw.ndim != 2 or raw.shape[1] != 3:
            raise ValueError("subscript indices must have shape (N, 3)")
        result = raw - base
        if np.any(result[:, 2] < 0):
            raise IndexError("resource port index is negative")
        return result

    flat = (raw.reshape(-1) - base).astype(np.int64)
    if np.any(flat < 0):
        raise IndexError("linear resource index is negative")
    plane_size = grid.shape[0] * grid.shape[1]
    subcarrier = flat % grid.shape[0]
    symbol = (flat // grid.shape[0]) % grid.shape[1]
    port = flat // plane_size
    return np.column_stack((subcarrier, symbol, port))


def _stable_unique(values: np.ndarray) -> np.ndarray:
    seen: set[tuple[int, ...]] = set()
    rows: list[np.ndarray] = []
    for row in values:
        key = tuple(int(item) for item in row)
        if key not in seen:
            seen.add(key)
            rows.append(row)
    if not rows:
        return np.empty((0, values.shape[1]), dtype=np.int64)
    return np.asarray(rows, dtype=np.int64)


def _parse_options(
    indices: np.ndarray,
    options: str | Sequence[str] | None,
) -> tuple[str, int, str]:
    raw = np.asarray(indices)
    style = "sub" if raw.ndim == 2 and raw.shape[1] == 3 else "ind"
    base = 0
    method = "allplanes"
    if options is None:
        return style, base, method
    tokens = (
        options.lower().split()
        if isinstance(options, str)
        else [str(item).lower() for item in options]
    )
    for token in tokens:
        if token in {"sub", "ind"}:
            style = token
        elif token == "0based":
            base = 0
        elif token == "1based":
            base = 1
        elif token in {"allplanes", "direct"}:
            method = token
        else:
            raise ValueError(f"unsupported resource extraction option: {token}")
    return style, base, method


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


__all__ = ["lte_extract_resources", "lte_resource_grid_size"]
