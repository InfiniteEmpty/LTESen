"""CRS-based LTE downlink channel estimation.

The estimator follows the interpolation path used by srsRAN_4G: it obtains
least-squares estimates on CRS, interpolates the reference symbols across
frequency with the LTE pilot spacing, and then interpolates across the
port-specific CRS symbols in time.  The public array contract remains close
to MATLAB's ``lteDLChannelEstimate`` while using Python's zero-based indexing
and ``(subcarrier, symbol, receive_antenna, transmit_port)`` axis order.
"""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from .cell_rs import lte_cell_rs, lte_cell_rs_indices
from ltesen.ltephy.common import lte_resource_grid_size


def lte_dl_channel_estimate(
    enb: Mapping[str, Any] | Any,
    rxgrid: np.ndarray,
    cec: Mapping[str, Any] | Any | None = None,
) -> tuple[np.ndarray, float]:
    """Estimate the downlink channel from LTE cell-specific reference signals.

    Parameters
    ----------
    enb:
        LTE cell configuration containing at least ``NDLRB``, ``NCellID`` and
        ``CellRefP``.  Python- and MATLAB-style field names are accepted.
    rxgrid:
        Resource grid with shape ``(subcarriers, symbols, receive_antennas)``.
        A two-dimensional grid is treated as one receive antenna.
    cec:
        Optional channel-estimator configuration.  The supported fields are
        ``PilotAverage`` (``"UserDefined"``), ``FreqWindow``, ``TimeWindow``
        and ``InterpType`` (``"none"``, ``"nearest"`` or linear-like
        interpolation).  MATLAB's other reference-signal branches are not
        silently selected here: ``Reference`` values other than CellRS raise
        ``NotImplementedError``.

    Returns
    -------
    hest, noise_est:
        ``hest`` has shape ``(subcarriers, symbols, receive_antennas,
        CellRefP)``.  ``noise_est`` is a non-negative scalar estimate from
        the residuals of the pilot observations after pilot averaging.

    Notes
    -----
    The implementation is intentionally focused on the CRS estimator needed
    by the acquisition flow.  ``UserDefined`` windows retain the current
    rectangular pilot smoothing interface; after smoothing, all MATLAB
    linear-like interpolation names use the srsRAN-style linear interpolator.
    MATLAB's other EVM-specific interpolation modes and pilot types are not
    silently selected here.
    """

    grid = np.asarray(rxgrid)
    if grid.ndim == 2:
        grid = grid[:, :, None]
    if grid.ndim != 3:
        raise ValueError("rxgrid must have shape (subcarriers, symbols, antennas)")
    if not np.issubdtype(grid.dtype, np.number):
        raise TypeError("rxgrid must be numeric")
    if not np.all(np.isfinite(grid)):
        raise ValueError("rxgrid must contain only finite values")

    n_sc, n_sym, n_rx = grid.shape
    expected_sc, symbols_per_subframe, n_ports = lte_resource_grid_size(enb)
    if n_sc != expected_sc:
        raise ValueError(
            f"rxgrid has {n_sc} subcarriers; configuration requires {expected_sc}"
        )
    if n_sym == 0 or n_sym % symbols_per_subframe:
        raise ValueError(
            "rxgrid must contain a positive whole number of LTE subframes"
        )

    config = _estimator_config(cec)
    pilot_average = str(
        _field(config, "pilot_average", "PilotAverage", default="UserDefined")
    ).lower()
    if pilot_average != "userdefined":
        raise NotImplementedError(
            "only CEC.PilotAverage='UserDefined' is implemented in the CRS estimator"
        )
    reference = str(_field(config, "reference", "Reference", default="CellRS"))
    if reference.lower() != "cellrs":
        raise NotImplementedError(
            "only CEC.Reference='CellRS' is implemented in the CRS estimator"
        )

    interp_type = str(
        _field(config, "interp_type", "InterpType", default="linear")
    ).lower()
    if interp_type not in {"none", "nearest", "linear", "natural", "cubic", "v4"}:
        raise ValueError(f"unsupported interpolation type: {interp_type}")
    freq_window = _positive_integer(
        _field(config, "freq_window", "FreqWindow", default=1), "FreqWindow"
    )
    time_window = _positive_integer(
        _field(config, "time_window", "TimeWindow", default=1), "TimeWindow"
    )

    hest = np.zeros((n_sc, n_sym, n_rx, n_ports), dtype=np.complex128)
    residuals: list[np.ndarray] = []
    for subframe in range(n_sym // symbols_per_subframe):
        subframe_cfg = _with_nsubframe(enb, subframe)
        for port in range(n_ports):
            pilot_sub = lte_cell_rs_indices(subframe_cfg, port, ["sub", "0based"])
            pilot_symbols = lte_cell_rs(subframe_cfg, port)
            if pilot_sub.shape[0] != pilot_symbols.shape[0]:
                raise RuntimeError("CRS index and symbol counts do not agree")

            local_sub = pilot_sub.copy()
            local_sub[:, 1] += subframe * symbols_per_subframe
            ls = np.empty((pilot_sub.shape[0], n_rx), dtype=np.complex128)
            for index, (subcarrier, symbol, _port) in enumerate(local_sub):
                observed = grid[subcarrier, symbol, :]
                expected = pilot_symbols[index]
                ls[index, :] = observed / expected

            smoothed = _average_pilots(
                pilot_sub, ls, freq_window, time_window
            )
            for index, (subcarrier, symbol, _port) in enumerate(local_sub):
                residuals.append(ls[index, :] - smoothed[index, :])

            if interp_type == "none":
                for index, (subcarrier, symbol, _port) in enumerate(local_sub):
                    hest[subcarrier, symbol, :, port] = smoothed[index, :]
            else:
                subframe_destination = hest[
                    :, subframe * symbols_per_subframe : (subframe + 1) * symbols_per_subframe, :, port
                ]
                _interpolate_port(subframe_destination, pilot_sub, smoothed, interp_type)

    if not residuals:
        return hest, 0.0
    residual = np.concatenate(residuals)
    noise_est = float(np.mean(np.abs(residual) ** 2))
    return hest, noise_est


def _average_pilots(
    locations: np.ndarray,
    values: np.ndarray,
    freq_window: int,
    time_window: int,
) -> np.ndarray:
    """Apply a rectangular average over the transmitted CRS pilots."""

    output = np.empty_like(values)
    for index, (subcarrier, symbol, _port) in enumerate(locations):
        freq_radius = freq_window // 2
        time_radius = time_window // 2
        mask = (
            (np.abs(locations[:, 0] - subcarrier) <= freq_radius)
            & (np.abs(locations[:, 1] - symbol) <= time_radius)
        )
        # For even windows, retain the requested number of samples on the
        # upper side when possible, matching a causal rectangular window's
        # deterministic behavior at pilot locations.
        if freq_window % 2 == 0:
            mask &= locations[:, 0] <= subcarrier + freq_radius
        if time_window % 2 == 0:
            mask &= locations[:, 1] <= symbol + time_radius
        if not np.any(mask):
            output[index, :] = values[index, :]
        else:
            output[index, :] = np.mean(values[mask, :], axis=0)
    return output


def _interpolate_port(
    destination: np.ndarray,
    locations: np.ndarray,
    values: np.ndarray,
    interp_type: str,
) -> None:
    """Fill one port using srsRAN's CRS frequency/time interpolation path.

    ``chest_dl.c`` first calls ``srsran_interp_linear_offset`` for every
    CRS-bearing symbol.  It then uses the port-specific symbol schedule and
    ``srsran_interp_linear_vector`` to fill the remaining OFDM symbols.  The
    two steps are kept separate here so their indexing is easy to compare
    with the LTE reference-signal locations.
    """

    if interp_type == "nearest":
        _interpolate_nearest_port(destination, locations, values)
        return

    _interpolate_srsran_port(destination, locations, values)


def _interpolate_srsran_port(
    destination: np.ndarray,
    locations: np.ndarray,
    values: np.ndarray,
) -> None:
    """Apply srsRAN-style frequency and time interpolation for one port."""

    n_sc, n_sym, n_rx = destination.shape
    if locations.size == 0:
        return

    # Each CRS symbol has pilots every six subcarriers.  srsRAN explicitly
    # extrapolates the first/last partial interval instead of clamping to the
    # edge pilot, which is important for the PBCH edge resource elements.
    for symbol in np.unique(locations[:, 1]):
        mask = locations[:, 1] == symbol
        known_subcarriers = locations[mask, 0]
        known_values = values[mask, :]
        destination[:, symbol, :] = _srsran_frequency_interpolate(
            n_sc, known_subcarriers, known_values, n_rx
        )

    _srsran_time_interpolate(destination, int(locations[0, 2]))


def _srsran_frequency_interpolate(
    n_sc: int,
    known_subcarriers: np.ndarray,
    known_values: np.ndarray,
    n_rx: int,
) -> np.ndarray:
    """Translate ``srsran_interp_linear_offset`` for a CRS frequency line."""

    order = np.argsort(known_subcarriers)
    x = np.asarray(known_subcarriers, dtype=np.int64)[order]
    y = np.asarray(known_values, dtype=np.complex128)[order]
    unique = np.concatenate(([True], np.diff(x) != 0))
    x = x[unique]
    y = y[unique, :]
    if x.size == 0:
        return np.zeros((n_sc, n_rx), dtype=np.complex128)
    if x.size == 1:
        return np.full((n_sc, n_rx), y[0, :], dtype=np.complex128)

    pilot_spacing = 6
    spacing = np.diff(x)
    if np.any(spacing != pilot_spacing):
        raise RuntimeError("CRS subcarriers are not spaced by six resource elements")
    offset = int(x[0] % pilot_spacing)
    output = np.empty((n_sc, n_rx), dtype=np.complex128)

    # This mirrors the leading extrapolation in srsran_interp_linear_offset.
    first_diff = (y[1, :] - y[0, :]) / pilot_spacing
    for index in range(offset):
        output[offset - index - 1, :] = y[0, :] - (index + 1) * first_diff

    # The C implementation writes M samples per interval, including the
    # left endpoint and excluding the right endpoint.
    for interval in range(x.size - 1):
        diff = (y[interval + 1, :] - y[interval, :]) / pilot_spacing
        start = offset + interval * pilot_spacing
        output[start : start + pilot_spacing, :] = (
            y[interval, :][None, :]
            + np.arange(pilot_spacing, dtype=np.float64)[:, None] * diff[None, :]
        )

    # Complete the final partial interval by extrapolating from the last two
    # pilot values.  The generated length is normally exactly n_sc for LTE.
    last_diff = y[-1, :] - y[-2, :]
    start = offset + (x.size - 1) * pilot_spacing
    count = min(pilot_spacing - offset, n_sc - start)
    if count > 0:
        output[start : start + count, :] = (
            y[-1, :][None, :]
            + np.arange(count, dtype=np.float64)[:, None] * last_diff[None, :] / pilot_spacing
        )

    # Guard against an unusual non-standard grid size.  Standard LTE grids
    # take the branch above completely; this keeps the helper total and makes
    # failures deterministic for future callers.
    if start + count < n_sc:
        output[start + count :, :] = y[-1, :]
    return output


def _srsran_time_interpolate(destination: np.ndarray, port: int) -> None:
    """Fill non-CRS symbols using srsRAN's normal/extended-CP schedules."""

    n_sc, n_sym, _ = destination.shape
    extended = n_sym == 12
    if extended:
        if port < 2:
            _fill_between(destination, 0, 3, (1, 2))
            _fill_between(destination, 3, 6, (4, 5))
            _fill_between(destination, 6, 9, (7, 8))
            _fill_extrapolated(destination, 6, 9, (10, 11))
        else:
            _fill_extrapolated(destination, 7, 1, (0,))
            _fill_between(destination, 1, 7, (2, 3, 4, 5, 6))
            _fill_between(destination, 1, 7, (8, 9, 10, 11))
        return

    if n_sym != 14:
        raise ValueError("LTE subframe must contain 12 or 14 OFDM symbols")
    if port < 2:
        _fill_between(destination, 0, 4, (1, 2, 3))
        _fill_between(destination, 4, 7, (5, 6))
        _fill_between(destination, 7, 11, (8, 9, 10))
        _fill_extrapolated(destination, 7, 11, (12, 13))
    else:
        _fill_extrapolated(destination, 8, 1, (0,))
        _fill_between(destination, 1, 8, (2, 3, 4, 5, 6, 7))
        _fill_between(destination, 1, 8, (9, 10, 11, 12, 13))


def _fill_between(
    destination: np.ndarray,
    left: int,
    right: int,
    targets: tuple[int, ...],
) -> None:
    """Linearly interpolate target symbol planes between two known planes."""

    if not targets:
        return
    denominator = float(right - left)
    slope = (destination[:, right, :] - destination[:, left, :]) / denominator
    for target in targets:
        destination[:, target, :] = destination[:, left, :] + (target - left) * slope


def _fill_extrapolated(
    destination: np.ndarray,
    left: int,
    right: int,
    targets: tuple[int, ...],
) -> None:
    """Extrapolate target symbol planes from the nearest CRS pair."""

    _fill_between(destination, left, right, targets)


def _interpolate_nearest_port(
    destination: np.ndarray,
    locations: np.ndarray,
    values: np.ndarray,
) -> None:
    """Retain the explicit nearest-neighbour mode for diagnostics."""

    n_sc, _, n_rx = destination.shape
    for symbol in np.unique(locations[:, 1]):
        mask = locations[:, 1] == symbol
        known = locations[mask, 0]
        for rx in range(n_rx):
            destination[:, symbol, rx] = _interp_1d(
                np.arange(n_sc), known, values[mask, rx], nearest=True
            )
    pilot_symbols = np.unique(locations[:, 1])
    for subcarrier in range(n_sc):
        for rx in range(n_rx):
            destination[subcarrier, :, rx] = _interp_1d(
                np.arange(destination.shape[1]),
                pilot_symbols,
                destination[subcarrier, pilot_symbols, rx],
                nearest=True,
            )


def _interp_1d(
    query: np.ndarray,
    known_x: np.ndarray,
    known_y: np.ndarray,
    *,
    nearest: bool,
) -> np.ndarray:
    order = np.argsort(known_x)
    x = np.asarray(known_x, dtype=np.int64)[order]
    y = np.asarray(known_y, dtype=np.complex128)[order]
    unique = np.concatenate(([True], np.diff(x) != 0))
    x = x[unique]
    y = y[unique]
    if x.size == 0:
        return np.zeros(query.shape, dtype=np.complex128)
    if x.size == 1:
        return np.full(query.shape, y[0], dtype=np.complex128)
    if nearest:
        right = np.searchsorted(x, query, side="left").clip(0, x.size - 1)
        left = np.maximum(right - 1, 0)
        choose_right = np.abs(x[right] - query) < np.abs(query - x[left])
        index = np.where(choose_right, right, left)
        return y[index]
    real = np.interp(query, x, y.real)
    imag = np.interp(query, x, y.imag)
    return real + 1j * imag


def _estimator_config(value: Mapping[str, Any] | Any | None) -> Mapping[str, Any] | Any:
    if value is None:
        return {}
    return value


def _with_nsubframe(value: Mapping[str, Any] | Any, offset: int) -> dict[str, Any]:
    result: dict[str, Any] = {}
    if isinstance(value, Mapping):
        result.update(value)
    else:
        for name in dir(value):
            if not name.startswith("_"):
                try:
                    item = getattr(value, name)
                except Exception:
                    continue
                if not callable(item):
                    result[name] = item
    current = _field(value, "nsubframe", "NSubframe", default=0)
    subframe = (int(current) + offset) % 10
    if "nsubframe" in result:
        result["nsubframe"] = subframe
    else:
        result["NSubframe"] = subframe
    return result


def _positive_integer(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be a positive integer")
    if not np.isfinite(value) or int(value) != value or int(value) < 1:
        raise ValueError(f"{name} must be a positive integer")
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


__all__ = ["lte_dl_channel_estimate"]
