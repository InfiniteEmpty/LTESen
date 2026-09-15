"""Downlink frame timing based on known LTE cell identity."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from .cell_search import (
    _pss_time_template,
    _sss_sequences,
    _top_peaks,
)
from ltesen.ltephy.common import LteOfdmInfo, lte_ofdm_info
from ltesen.ltephy.ofdm import (
    OfdmPlan,
    build_ofdm_plan,
    lte_ofdm_demodulate,
)
from ltesen.ltephy.ch_estimation import lte_cell_rs, lte_cell_rs_indices


def lte_dl_frame_offset(
    enb: Mapping[str, Any] | Any,
    waveform: np.ndarray,
    correlation_config: Mapping[str, Any] | str | None = None,
    *,
    return_correlation: bool = False,
) -> int | tuple[int, np.ndarray]:
    """Estimate the offset from ``waveform`` to the first LTE frame.

    ``enb`` must contain ``NDLRB`` and ``NCellID``.  The waveform is shaped
    ``(samples, receive_antennas)`` or ``(samples,)``.  The returned offset is
    zero-based and may be negative when the first frame starts before the
    supplied waveform.

    The implementation covers PSS+SSS timing and MATLAB-style CellRS timing.
    When CellRS is enabled it refines each known-cell PSS/SSS candidate over a
    short sample neighborhood using the CRS extracted from the demodulated
    first subframe.  ``correlation_config`` accepts MATLAB-style ``PSS``,
    ``SSS`` and ``CellRS`` keys, including ``OmitEdgeRBs``.
    """

    info = lte_ofdm_info(enb)
    cell_id = _integer_field(enb, "ncellid", "NCellID")
    if cell_id < 0 or cell_id > 503:
        raise ValueError("ncellid must be in [0, 503]")
    values = _as_waveform(waveform)
    config = _normalise_correlation_config(correlation_config)
    cellrs_on = config["cellrs"] in {"on", "omitedgerbs"}
    crs_cache = _build_frame_timing_crs_cache(enb) if cellrs_on else None
    ofdm_plan = (
        build_ofdm_plan(
            info,
            int(_field(enb, "ndlrb", "NDLRB")),
            cp_fraction=0.55,
            sample_count=_subframe_length(info),
        )
        if cellrs_on
        else None
    )
    if config["pss"] == "off" and config["sss"] == "off" and not cellrs_on:
        zero_offset = 0
        if return_correlation:
            return zero_offset, np.zeros_like(values, dtype=np.complex64)
        return zero_offset

    correlation = np.zeros_like(values, dtype=np.complex64)
    candidates: list[tuple[float, int, int]] = []
    nid2 = cell_id % 3
    if config["pss"] == "on":
        template = _pss_time_template(info, nid2)
        pss_correlation = _matched_filter(values, template)
        correlation[: pss_correlation.shape[0], :] = pss_correlation
        metric = np.max(np.abs(pss_correlation), axis=1)
        # Retain more than one PSS occurrence so a 10 ms frame can be found
        # even when the input starts near subframe 5.
        candidate_count = max(2, int(np.ceil(values.shape[0] / max(_half_frame_length(info), 1))) + 2)
        positions = _top_peaks(metric, candidate_count, max(info.nfft // 8, 1))
        candidates = [(float(metric[pos]), pos, 0) for pos in positions]
    elif not cellrs_on:
        raise NotImplementedError("SSS-only frame timing is not implemented yet")

    nid1 = cell_id // 3
    scored: list[tuple[float, int, int]] = []
    if candidates:
        for pss_peak, pss_start, _ in candidates:
            subframe = 0
            sss_peak = 0.0
            if config["sss"] == "on":
                match = _match_known_sss(info, values, pss_start, nid1, nid2)
                if match is None:
                    continue
                subframe, sss_peak = match
            offset = _frame_offset(info, pss_start, subframe, enb)
            if cellrs_on:
                offset, cellrs_peak = _refine_with_cellrs(
                    enb, values, offset, config["cellrs"] == "omitedgerbs",
                    config["cellrs_search_radius"],
                    info=info,
                    crs_cache=crs_cache,
                    ofdm_plan=ofdm_plan,
                )
            else:
                cellrs_peak = 0.0
            # Keep PSS as the anchor and use the known-cell SSS/CRS scores as
            # additional discriminators, matching MATLAB's magnitude-sum
            # correlation strategy.
            scored.append((pss_peak + sss_peak + cellrs_peak, offset, subframe))

    if not scored and cellrs_on and config["pss"] == "off" and config["sss"] == "off":
        scored = _cellrs_only_candidates(
            enb,
            values,
            config["cellrs"] == "omitedgerbs",
            info=info,
            crs_cache=crs_cache,
            ofdm_plan=ofdm_plan,
        )

    if not scored:
        raise ValueError("LTE PSS/SSS frame timing did not find the requested cell")
    # With a known cell, SSS is the primary discriminator; among repeated
    # occurrences keep the earliest frame with the strongest same-cell score.
    scored.sort(key=lambda item: (-item[0], item[1]))
    offset = int(scored[0][1])
    if return_correlation:
        return offset, correlation
    return offset


def _normalise_correlation_config(
    config: Mapping[str, Any] | str | None,
) -> dict[str, Any]:
    if isinstance(config, str):
        if config.lower() != "testevm":
            raise ValueError("correlation_config string must be 'TestEVM'")
        return {
            "pss": "on",
            "sss": "off",
            "cellrs": "omitedgerbs",
            "cellrs_search_radius": 0,
        }
    value = config or {}
    radius = _field(
        value,
        "cellrs_search_radius",
        "cellrs_search_radius_samples",
        "CellRSSearchRadius",
        "CellRSSearchRadiusSamples",
        default=0,
    )
    if isinstance(radius, bool) or not isinstance(radius, (Integral, Real)):
        raise ValueError("cellrs_search_radius must be a non-negative integer")
    if not np.isfinite(radius) or int(radius) != radius or int(radius) < 0:
        raise ValueError("cellrs_search_radius must be a non-negative integer")
    return {
        "pss": _mode(_field(value, "pss", "PSS", default="On")),
        "sss": _mode(_field(value, "sss", "SSS", default="On")),
        "cellrs": _mode(_field(value, "cellrs", "CellRS", default="Off")),
        "cellrs_search_radius": int(radius),
    }


def _mode(value: Any) -> str:
    if isinstance(value, bool):
        return "on" if value else "off"
    return str(value).lower().replace("_", "")


def _build_frame_timing_crs_cache(
    enb: Mapping[str, Any] | Any,
) -> tuple[np.ndarray, np.ndarray]:
    """Build the fixed subframe-0, port-0 CRS data used by timing search."""

    cell_config = {
        "ndlrb": _field(enb, "ndlrb", "NDLRB"),
        "ncellid": _field(enb, "ncellid", "NCellID"),
        "cyclic_prefix": _field(
            enb, "cyclic_prefix", "CyclicPrefix", default="Normal"
        ),
        "duplex_mode": _field(enb, "duplex_mode", "DuplexMode", default="FDD"),
        "nsubframe": 0,
    }
    locations = lte_cell_rs_indices(cell_config, 0, ["sub", "0based"])
    references = lte_cell_rs(cell_config, 0)
    return locations, references


def _refine_with_cellrs(
    enb: Mapping[str, Any] | Any,
    waveform: np.ndarray,
    offset: int,
    omit_edge_rbs: bool,
    search_radius: int,
    *,
    info: LteOfdmInfo | None = None,
    crs_cache: tuple[np.ndarray, np.ndarray] | None = None,
    ofdm_plan: OfdmPlan | None = None,
) -> tuple[int, float]:
    """Refine a known-cell frame offset using first-subframe CRS."""

    info = lte_ofdm_info(enb) if info is None else info
    if search_radius <= 0:
        default_radius = max(4, info.nfft // 32)
        search_radius = min(default_radius, info.cyclic_prefix_lengths[0])
    frame_length = 10 * _subframe_length(info)
    # The MATLAB offset is periodic over one LTE frame.  For a short search
    # waveform, keep the candidate in the supplied buffer when possible.
    centers = [offset]
    if offset < 0:
        centers.append(offset + frame_length)
    best_offset = offset
    best_score = 0.0
    for center in centers:
        for delta in range(-search_radius, search_radius + 1):
            candidate = center + delta
            score = _cellrs_frame_score(
                enb,
                waveform,
                candidate,
                omit_edge_rbs,
                info=info,
                crs_cache=crs_cache,
                ofdm_plan=ofdm_plan,
            )
            if score > best_score:
                best_score = score
                best_offset = candidate
    return best_offset, best_score


def _cellrs_frame_score(
    enb: Mapping[str, Any] | Any,
    waveform: np.ndarray,
    frame_offset: int,
    omit_edge_rbs: bool,
    *,
    info: LteOfdmInfo | None = None,
    crs_cache: tuple[np.ndarray, np.ndarray] | None = None,
    ofdm_plan: OfdmPlan | None = None,
) -> float:
    """Return normalized CRS correlation for a candidate frame start."""

    info = lte_ofdm_info(enb) if info is None else info
    subframe_length = _subframe_length(info)
    if frame_offset < 0 or frame_offset + subframe_length > waveform.shape[0]:
        return 0.0
    cell_config = {
        "ndlrb": _field(enb, "ndlrb", "NDLRB"),
        "ncellid": _field(enb, "ncellid", "NCellID"),
        "cyclic_prefix": _field(enb, "cyclic_prefix", "CyclicPrefix", default="Normal"),
        "duplex_mode": _field(enb, "duplex_mode", "DuplexMode", default="FDD"),
        "nsubframe": 0,
    }
    try:
        if crs_cache is None:
            locations = lte_cell_rs_indices(cell_config, 0, ["sub", "0based"])
            references = lte_cell_rs(cell_config, 0)
        else:
            locations, references = crs_cache
        grid = lte_ofdm_demodulate(
            cell_config,
            waveform[frame_offset : frame_offset + subframe_length, :],
            cp_fraction=0.55,
            plan=ofdm_plan,
        )
    except (NotImplementedError, ValueError, IndexError):
        return 0.0
    if grid.shape[1] < max(locations[:, 1]) + 1:
        return 0.0

    ncrs_per_symbol = 2 * int(cell_config["ndlrb"])
    scores: list[float] = []
    for group_start in range(0, references.size, ncrs_per_symbol):
        group_end = group_start + ncrs_per_symbol
        group_locations = locations[group_start:group_end]
        group_references = references[group_start:group_end]
        if omit_edge_rbs:
            # Two CRS tones belong to each resource block in one OFDM symbol.
            keep = np.arange(group_references.size)
            keep = keep[(keep >= 2) & (keep < group_references.size - 2)]
            group_locations = group_locations[keep]
            group_references = group_references[keep]
        if group_references.size == 0:
            continue
        observed = grid[
            group_locations[:, 0], group_locations[:, 1], :
        ]
        numerator = np.abs(np.sum(np.conj(group_references[:, None]) * observed, axis=0))
        denominator = np.sqrt(
            np.sum(np.abs(group_references[:, None]) ** 2, axis=0)
            * np.sum(np.abs(observed) ** 2, axis=0)
        )
        per_antenna = np.divide(
            numerator,
            denominator,
            out=np.zeros_like(numerator, dtype=float),
            where=denominator > 0,
        )
        scores.append(float(np.max(per_antenna)))
    return float(np.mean(scores)) if scores else 0.0


def _cellrs_only_candidates(
    enb: Mapping[str, Any] | Any,
    waveform: np.ndarray,
    omit_edge_rbs: bool,
    *,
    info: LteOfdmInfo | None = None,
    crs_cache: tuple[np.ndarray, np.ndarray] | None = None,
    ofdm_plan: OfdmPlan | None = None,
) -> list[tuple[float, int, int]]:
    """Find frame candidates from CP peaks when PSS/SSS are disabled."""

    info = lte_ofdm_info(enb) if info is None else info
    starts = _cp_peaks(waveform, info)
    symbol_offsets = _symbol_starts(info, 10)
    candidates: list[tuple[float, int, int]] = []
    seen: set[int] = set()
    for symbol_start, cp_score in starts:
        for symbol_offset in symbol_offsets:
            frame_start = symbol_start - symbol_offset
            if frame_start in seen:
                continue
            seen.add(frame_start)
            score = _cellrs_frame_score(
                enb,
                waveform,
                frame_start,
                omit_edge_rbs,
                info=info,
                crs_cache=crs_cache,
                ofdm_plan=ofdm_plan,
            )
            if score > 0:
                candidates.append((score + cp_score, frame_start, 0))
    candidates.sort(key=lambda item: (-item[0], item[1]))
    return candidates[:16]


def _cp_peaks(waveform: np.ndarray, info: LteOfdmInfo) -> list[tuple[int, float]]:
    """Return strong cyclic-prefix positions for CRS-only timing."""

    sample_count = waveform.shape[0]
    products = []
    for cp_length in sorted(set(info.cyclic_prefix_lengths)):
        if sample_count <= info.nfft + cp_length:
            continue
        # The rolling sum supplies the correlation at every possible sample
        # position; CP lengths alternate between the first and later symbols.
        pair = waveform[:-info.nfft, :] * np.conj(waveform[info.nfft :, :])
        cumulative = np.vstack(
            (
                np.zeros((1, waveform.shape[1]), dtype=np.complex64),
                np.cumsum(pair, axis=0),
            )
        )
        correlation = cumulative[cp_length:] - cumulative[:-cp_length]
        left_power = np.abs(waveform[:-info.nfft, :]) ** 2
        right_power = np.abs(waveform[info.nfft :, :]) ** 2
        left_cumulative = np.vstack(
            (np.zeros((1, waveform.shape[1])), np.cumsum(left_power, axis=0))
        )
        right_cumulative = np.vstack(
            (np.zeros((1, waveform.shape[1])), np.cumsum(right_power, axis=0))
        )
        left_energy = left_cumulative[cp_length:] - left_cumulative[:-cp_length]
        right_energy = right_cumulative[cp_length:] - right_cumulative[:-cp_length]
        denominator = np.sqrt(left_energy * right_energy)
        metric = np.divide(
            np.abs(correlation),
            denominator,
            out=np.zeros_like(np.abs(correlation)),
            where=denominator > 0,
        )
        metric_by_position = np.max(metric, axis=1)
        padded_metric = np.zeros(sample_count - info.nfft, dtype=float)
        padded_metric[: metric_by_position.size] = metric_by_position
        products.append(padded_metric)
    if not products:
        return []
    metric = np.max(np.vstack(products), axis=0)
    count = min(32, max(8, sample_count // max(info.nfft, 1)))
    positions = _top_peaks(metric, count, max(info.nfft // 2, 1))
    return [(position, float(metric[position])) for position in positions]


def _symbol_starts(info: LteOfdmInfo, subframes: int) -> tuple[int, ...]:
    starts: list[int] = []
    position = 0
    for _ in range(subframes):
        for cp_length in info.cyclic_prefix_lengths:
            starts.append(position)
            position += info.nfft + cp_length
    return tuple(starts)


def _match_known_sss(
    info: LteOfdmInfo,
    waveform: np.ndarray,
    pss_start: int,
    nid1: int,
    nid2: int,
) -> tuple[int, float] | None:
    sss_index = info.pss_symbol_index - 1
    sss_start = pss_start - (info.nfft + info.cyclic_prefix_lengths[sss_index])
    data_start = sss_start + info.cyclic_prefix_lengths[sss_index]
    data_end = data_start + info.nfft
    if data_start < 0 or data_end > waveform.shape[0]:
        return None
    spectrum = np.fft.fft(waveform[data_start:data_end, :], axis=0) / np.sqrt(info.nfft)
    bins = np.concatenate((np.arange(info.nfft - 31, info.nfft), np.arange(1, 32)))
    observed = spectrum[bins, :]
    sequence0, sequence5 = _sss_sequences(nid1, nid2)
    scores = []
    denominator = np.sqrt(62.0 * np.sum(np.abs(observed) ** 2, axis=0))
    for sequence in (sequence0, sequence5):
        per_antenna = np.divide(
            np.abs(sequence @ observed),
            denominator,
            out=np.zeros(observed.shape[1]),
            where=denominator > 0,
        )
        scores.append(float(np.max(per_antenna)))
    subframe = int(np.argmax(scores) * 5)
    return subframe, scores[subframe // 5]


def _matched_filter(waveform: np.ndarray, template: np.ndarray) -> np.ndarray:
    sample_count, antenna_count = waveform.shape
    template_count = template.size
    convolution_count = sample_count + template_count - 1
    fft_size = 1 << (convolution_count - 1).bit_length()
    kernel = np.conj(template[::-1])
    convolution = np.fft.ifft(
        np.fft.fft(waveform, n=fft_size, axis=0)
        * np.fft.fft(kernel, n=fft_size)[:, None],
        axis=0,
    )
    valid = convolution[template_count - 1 : sample_count, :]
    power = np.abs(waveform) ** 2
    cumulative = np.vstack((np.zeros((1, antenna_count)), np.cumsum(power, axis=0)))
    window_power = cumulative[template_count:] - cumulative[:-template_count]
    denominator = np.sqrt(window_power * np.sum(np.abs(template) ** 2))
    return np.divide(
        valid,
        denominator,
        out=np.zeros_like(valid),
        where=denominator > 0,
    )


def _frame_offset(info: LteOfdmInfo, pss_start: int, subframe: int, enb: Any) -> int:
    mode = str(_field(enb, "duplex_mode", "DuplexMode", default="FDD")).lower()
    pss_subframe = subframe if mode != "tdd" else subframe + 1
    return int(pss_start - pss_subframe * _subframe_length(info) - info.pss_offset)


def _subframe_length(info: LteOfdmInfo) -> int:
    return int(sum(info.nfft + cp for cp in info.cyclic_prefix_lengths))


def _half_frame_length(info: LteOfdmInfo) -> int:
    return 5 * _subframe_length(info)


def _as_waveform(waveform: np.ndarray) -> np.ndarray:
    values = np.asarray(waveform)
    if values.ndim == 1:
        values = values[:, None]
    if values.ndim != 2 or values.shape[1] == 0:
        raise ValueError("waveform must have shape (samples, antennas)")
    if not np.issubdtype(values.dtype, np.number) or not np.all(np.isfinite(values)):
        raise ValueError("waveform must be finite numeric data")
    return values.astype(np.complex64, copy=False)


def _integer_field(value: Mapping[str, Any] | Any, *names: str) -> int:
    raw = _field(value, *names)
    if isinstance(raw, bool) or not isinstance(raw, (Integral, Real)):
        raise ValueError(f"{names[0]} must be an integer")
    if not np.isfinite(raw) or int(raw) != raw:
        raise ValueError(f"{names[0]} must be an integer")
    return int(raw)


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


__all__ = ["lte_dl_frame_offset"]
