"""Array extraction helper for LTE resource-element indices."""

from __future__ import annotations

from typing import Sequence

import numpy as np


def lte_extract_resources(
    indices: np.ndarray,
    *grids: np.ndarray,
    options: str | Sequence[str] | None = None,
    return_indices: bool = False,
) -> np.ndarray | tuple[np.ndarray, ...] | tuple[object, object]:
    """Extract resource elements from one or more resource grids.

    ``indices`` may be a zero-based linear array/matrix or a zero-based
    ``(subcarrier, symbol, port)`` array.  The style can be explicit with
    ``"ind"`` or ``"sub"``; otherwise an ``N-by-3`` array is treated as
    subscript indices.  Python defaults to zero-based indexing and the
    ``"allplanes"`` method, which is the useful form for a received grid and
    a multi-port channel-estimate grid.

    With ``allplanes`` (the default), port columns in the input identify the
    same time-frequency locations and are projected over all receive and
    fourth-dimension planes of each grid.  A 3-D grid returns
    ``(NRE, NRx)``; a 4-D grid returns ``(NRE, NRx, P)``.  ``"direct"`` keeps
    the supplied port for each subscript row and is provided for simple
    per-plane extraction.

    One grid returns one array.  Multiple grids return a tuple in the same
    order.  If ``return_indices=True``, the function returns
    ``(resources, used_subscripts)`` for one grid or
    ``(resources_tuple, used_subscripts)`` for multiple grids.
    """

    if not grids:
        raise ValueError("at least one resource grid is required")
    style, base, method = _parse_options(indices, options)
    positions = _to_subscripts(indices, style=style, base=base, grid=np.asarray(grids[0]))
    if method == "allplanes":
        positions = _stable_unique(positions[:, :2])
    outputs = tuple(_extract_grid(np.asarray(grid), positions, method) for grid in grids)
    result: np.ndarray | tuple[np.ndarray, ...] = outputs[0] if len(outputs) == 1 else outputs
    if not return_indices:
        return result
    used = positions.copy()
    return result, used


def _extract_grid(grid: np.ndarray, positions: np.ndarray, method: str) -> np.ndarray:
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


def _to_subscripts(indices: np.ndarray, *, style: str, base: int, grid: np.ndarray) -> np.ndarray:
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
    tokens = options.lower().split() if isinstance(options, str) else [str(x).lower() for x in options]
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


__all__ = ["lte_extract_resources"]
