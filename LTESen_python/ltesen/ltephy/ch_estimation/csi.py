"""Direct CRS extraction for the streaming CSI path."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from .cell_rs import lte_cell_rs, lte_cell_rs_indices
from ltesen.ltephy.common import lte_resource_grid_size


class CrsReferenceCache:
    """Precomputed CRS locations and reference symbols for one LTE cell.

    CRS locations depend only on the static cell/grid configuration.  The
    reference symbols additionally depend on ``NSubframe``, so all ten LTE
    subframe variants are generated once when the cache is constructed.
    """

    def __init__(self, enb: Mapping[str, Any] | Any) -> None:
        self._enb = {
            "ndlrb": _field(enb, "ndlrb", "NDLRB"),
            "ncellid": _field(enb, "ncellid", "NCellID"),
            "cell_ref_p": _field(enb, "cell_ref_p", "CellRefP"),
            "cyclic_prefix": _field(
                enb, "cyclic_prefix", "CyclicPrefix", default="Normal"
            ),
            "duplex_mode": _field(
                enb, "duplex_mode", "DuplexMode", default="FDD"
            ),
            "nsubframe": 0,
        }
        self.signature = _signature(self._enb)
        _, _, self.n_ports = lte_resource_grid_size(self._enb)
        self.locations = tuple(
            _readonly(lte_cell_rs_indices(self._enb, port, ["sub", "0based"]))
            for port in range(self.n_ports)
        )
        self.references = tuple(
            tuple(
                _readonly(
                    lte_cell_rs(
                        {**self._enb, "nsubframe": subframe},
                        port,
                    )
                )
                for port in range(self.n_ports)
            )
            for subframe in range(10)
        )

    def for_subframe(self, nsubframe: int) -> tuple[np.ndarray, ...]:
        """Return the cached CRS vectors for an LTE subframe number."""

        if (
            isinstance(nsubframe, bool)
            or not isinstance(nsubframe, (Integral, Real))
            or not np.isfinite(nsubframe)
            or int(nsubframe) != nsubframe
            or not 0 <= int(nsubframe) <= 9
        ):
            raise ValueError("nsubframe must be an integer in [0, 9]")
        return self.references[int(nsubframe)]


def lte_crs_csi(
    enb: Mapping[str, Any] | Any,
    rxgrid: np.ndarray,
    *,
    reference_cache: CrsReferenceCache | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Extract the two CRS groups used by the CSI tracker.

    The return value is ``(g1, g2, index_g1, index_g2)``.  ``g1`` and ``g2``
    have shape ``(2*NDLRB, 2, NRx, CellRefP)`` and contain direct LS CRS
    estimates.  The index arrays are zero-based active-grid subcarrier
    indices with shape ``(2*NDLRB, CellRefP)``.

    This is the Python counterpart of the project's ``fastDLCSIEstimate``.
    The streaming CSI contract currently supports Normal/Extended FDD with
    one or two transmit ports; four-port PBCH acquisition remains supported
    separately, but ports 2/3 have only two CRS-bearing symbols and need a
    different CSI grouping.
    """

    grid = np.asarray(rxgrid, dtype=np.complex64)
    if grid.ndim == 2:
        grid = grid[:, :, None]
    if grid.ndim != 3 or not np.all(np.isfinite(grid)):
        raise ValueError("rxgrid must have shape (subcarriers, symbols, antennas)")
    n_sc, n_sym, n_rx = grid.shape
    expected_sc, expected_symbols, n_ports = lte_resource_grid_size(enb)
    if (n_sc, n_sym) != (expected_sc, expected_symbols):
        raise ValueError(
            "rxgrid shape does not match the configured LTE subframe "
            f"({expected_sc}, {expected_symbols})"
        )
    if n_ports > 2:
        raise NotImplementedError(
            "streaming CRS CSI grouping currently supports at most two transmit ports"
        )

    n_crs = 2 * (expected_sc // 12)
    g1 = np.empty((n_crs, 2, n_rx, n_ports), dtype=np.complex64)
    g2 = np.empty_like(g1)
    index_g1 = np.empty((n_crs, n_ports), dtype=np.int64)
    index_g2 = np.empty_like(index_g1)

    if reference_cache is None:
        # Preserve the standalone API.  Streaming callers should construct
        # one cache during initialization and pass it on every subframe.
        reference_cache = CrsReferenceCache(enb)
    if reference_cache.n_ports != n_ports:
        raise ValueError("reference_cache does not match the configured CellRefP")
    if reference_cache.signature != _signature(enb):
        raise ValueError("reference_cache does not match the configured LTE cell")
    nsubframe = _field(enb, "nsubframe", "NSubframe", default=0)
    references = reference_cache.for_subframe(nsubframe)

    for port in range(n_ports):
        locations = reference_cache.locations[port]
        reference = references[port]
        unique_symbols = np.unique(locations[:, 1])
        if unique_symbols.size != 4:
            raise NotImplementedError(
                "CRS CSI grouping requires four CRS symbols for each transmit port"
            )
        groups: list[np.ndarray] = []
        for symbol in unique_symbols:
            mask = locations[:, 1] == symbol
            groups.append(
                grid[locations[mask, 0], symbol, :] / reference[mask, None]
            )

        index_g1[:, port] = locations[locations[:, 1] == unique_symbols[0], 0]
        index_g2[:, port] = locations[locations[:, 1] == unique_symbols[1], 0]
        g1[:, 0, :, port] = groups[0]
        g1[:, 1, :, port] = groups[2]
        g2[:, 0, :, port] = groups[1]
        g2[:, 1, :, port] = groups[3]

    return g1, g2, index_g1, index_g2


def _readonly(value: np.ndarray) -> np.ndarray:
    array = np.asarray(value)
    array.setflags(write=False)
    return array


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


def _signature(enb: Mapping[str, Any] | Any) -> tuple[Any, ...]:
    return (
        _field(enb, "ndlrb", "NDLRB"),
        _field(enb, "ncellid", "NCellID"),
        _field(enb, "cell_ref_p", "CellRefP"),
        str(_field(enb, "cyclic_prefix", "CyclicPrefix", default="Normal")).lower(),
        str(_field(enb, "duplex_mode", "DuplexMode", default="FDD")).lower(),
    )


__all__ = ["CrsReferenceCache", "lte_crs_csi"]
