"""PSS/SSS based LTE cell search.

This is intentionally a small, inspectable primitive rather than a hidden
replacement for the complete MATLAB LTE Toolbox.  It implements the cell
identity and timing boundary needed by the current acquisition design, while
leaving later CFO/channel-estimation refinements explicit.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping

import numpy as np

from .ofdm_info import LteOfdmInfo, lte_ofdm_info


class CellSearchError(RuntimeError):
    """Raised when no valid PSS/SSS candidate can be found."""


@dataclass(frozen=True)
class CellSearchResult:
    """One result row from :func:`cell_search`."""

    cell_id: int
    offset: int
    peak: float
    pss_peak: float
    sss_peak: float
    subframe: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "cell_id": self.cell_id,
            "offset": self.offset,
            "peak": self.peak,
            "pss_peak": self.pss_peak,
            "sss_peak": self.sss_peak,
            "subframe": self.subframe,
        }


def cell_search(
    enb: Mapping[str, Any] | Any,
    waveform: np.ndarray,
    algorithm: Mapping[str, Any] | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Search LTE PSS/SSS and return ``(cell_ids, offsets, peaks)``.

    ``waveform`` has shape ``(samples, receive_antennas)``; a one-dimensional
    waveform is accepted.  Returned offsets and resource indices use Python's
    zero-based convention.  Algorithm keys may use either Python names
    (``max_cell_count``, ``sss_detection``, ``cell_ids``) or the MATLAB names
    from ``MATLAB_LIB_REFER.md``.

    The PreFFT and PostFFT settings share the same numerically transparent
    SSS observation here: PSS provides timing, then the SSS OFDM symbol is
    extracted and correlated.  The setting is nevertheless validated and
    retained in the API so the later optimized PostFFT path can be substituted
    without changing acquisition callers.
    """

    info = lte_ofdm_info(enb)
    samples = _as_waveform(waveform)
    config = _normalise_algorithm(algorithm)
    _validate_algorithm(config)
    cell_ids = config["cell_ids"]
    max_count = config["max_cell_count"]
    allowed_nid2 = sorted({cell_id % 3 for cell_id in cell_ids})
    if samples.shape[0] < _subframe_length(info):
        raise CellSearchError("waveform must contain at least one LTE subframe")

    pss_candidates: list[tuple[float, int, int]] = []
    cp_length = info.cyclic_prefix_lengths[info.pss_symbol_index]
    pss_template_length = info.nfft + cp_length
    for nid2 in allowed_nid2:
        template = _pss_time_template(info, nid2)
        metric = _normalised_matched_filter(samples, template)
        for position in _top_peaks(metric, max_count, max(cp_length, 1)):
            if position + pss_template_length <= samples.shape[0]:
                pss_candidates.append((float(metric[position]), position, nid2))

    pss_candidates.sort(reverse=True)
    candidates: list[CellSearchResult] = []
    for pss_peak, pss_start, nid2 in pss_candidates:
        sss_result = _match_sss(info, samples, pss_start, nid2)
        if sss_result is None:
            continue
        nid1, subframe, sss_peak = sss_result
        cell_id = 3 * nid1 + nid2
        if cell_id not in cell_ids:
            continue
        offset = _frame_offset(info, pss_start, subframe, enb)
        candidates.append(
            CellSearchResult(
                cell_id=cell_id,
                offset=offset,
                peak=pss_peak + sss_peak,
                pss_peak=pss_peak,
                sss_peak=sss_peak,
                subframe=subframe,
            )
        )

    best_by_cell: dict[int, CellSearchResult] = {}
    for candidate in candidates:
        previous = best_by_cell.get(candidate.cell_id)
        if previous is None or candidate.peak > previous.peak:
            best_by_cell[candidate.cell_id] = candidate
    results = sorted(best_by_cell.values(), key=lambda item: item.peak, reverse=True)[:max_count]
    if not results:
        raise CellSearchError("LTE PSS/SSS cell search did not find a valid cell")
    return (
        np.asarray([item.cell_id for item in results], dtype=np.int64),
        np.asarray([item.offset for item in results], dtype=np.int64),
        np.asarray([item.peak for item in results], dtype=float),
    )


def _normalise_algorithm(algorithm: Mapping[str, Any] | None) -> dict[str, Any]:
    value = algorithm or {}
    cell_ids = _field(value, "cell_ids", "CellIDs", default=None)
    if cell_ids is None:
        cell_ids = range(504)
    ids = sorted({int(item) for item in cell_ids})
    return {
        "cell_ids": ids,
        "max_cell_count": int(_field(value, "max_cell_count", "MaxCellCount", default=1)),
        "sss_detection": str(
            _field(value, "sss_detection", "SSSDetection", default="PreFFT")
        ).lower().replace("_", ""),
    }


def _validate_algorithm(config: Mapping[str, Any]) -> None:
    ids = config["cell_ids"]
    if not ids or any(item < 0 or item > 503 for item in ids):
        raise ValueError("cell_ids must contain integers in [0, 503]")
    max_count = config["max_cell_count"]
    if max_count < 1 or max_count > 504:
        raise ValueError("max_cell_count must be in [1, 504]")
    if config["sss_detection"] not in {"prefft", "postfft"}:
        raise ValueError("sss_detection must be 'PreFFT' or 'PostFFT'")


def _as_waveform(waveform: np.ndarray) -> np.ndarray:
    values = np.asarray(waveform)
    if values.ndim == 1:
        values = values[:, None]
    if values.ndim != 2 or values.shape[1] == 0:
        raise ValueError("waveform must have shape (samples, receive_antennas)")
    if not np.issubdtype(values.dtype, np.number) or not np.all(np.isfinite(values)):
        raise ValueError("waveform must be finite numeric data")
    return values.astype(np.complex128, copy=False)


def _pss_sequence(nid2: int) -> np.ndarray:
    if nid2 not in (0, 1, 2):
        raise ValueError("nid2 must be in [0, 2]")
    roots = (25.0, 29.0, 34.0)
    n = np.arange(62, dtype=float)
    phase = np.empty(62, dtype=float)
    phase[:31] = -np.pi * roots[nid2] * n[:31] * (n[:31] + 1) / 63
    phase[31:] = -np.pi * roots[nid2] * (n[31:] + 2) * (n[31:] + 1) / 63
    return np.exp(1j * phase)


def _pss_time_template(info: LteOfdmInfo, nid2: int) -> np.ndarray:
    spectrum = np.zeros(info.nfft, dtype=np.complex128)
    sequence = _pss_sequence(nid2)
    spectrum[-31:] = sequence[:31]
    spectrum[1:32] = sequence[31:]
    useful = np.fft.ifft(spectrum) * np.sqrt(info.nfft)
    cp = info.cyclic_prefix_lengths[info.pss_symbol_index]
    return np.concatenate((useful[-cp:], useful))


def _normalised_matched_filter(waveform: np.ndarray, template: np.ndarray) -> np.ndarray:
    sample_count, antenna_count = waveform.shape
    template_count = template.size
    convolution_count = sample_count + template_count - 1
    fft_size = 1 << (convolution_count - 1).bit_length()
    kernel = np.conj(template[::-1])
    signal_fft = np.fft.fft(waveform, n=fft_size, axis=0)
    kernel_fft = np.fft.fft(kernel, n=fft_size)[:, None]
    convolution = np.fft.ifft(signal_fft * kernel_fft, axis=0)
    correlation = convolution[template_count - 1 : sample_count, :]

    power = np.abs(waveform) ** 2
    cumulative = np.vstack((np.zeros((1, antenna_count)), np.cumsum(power, axis=0)))
    window_power = cumulative[template_count:] - cumulative[:-template_count]
    denominator = np.sqrt(window_power * np.sum(np.abs(template) ** 2))
    per_antenna = np.divide(
        np.abs(correlation), denominator, out=np.zeros_like(np.abs(correlation)), where=denominator > 0
    )
    return np.max(per_antenna, axis=1)


def _top_peaks(values: np.ndarray, count: int, minimum_distance: int) -> list[int]:
    selected: list[int] = []
    for index in np.argsort(values)[::-1]:
        position = int(index)
        if all(abs(position - previous) >= minimum_distance for previous in selected):
            selected.append(position)
            if len(selected) == count:
                break
    return selected


def _match_sss(
    info: LteOfdmInfo,
    waveform: np.ndarray,
    pss_start: int,
    nid2: int,
) -> tuple[int, int, float] | None:
    sss_symbol_index = info.pss_symbol_index - 1
    sss_start = pss_start - (info.nfft + info.cyclic_prefix_lengths[sss_symbol_index])
    data_start = sss_start + info.cyclic_prefix_lengths[sss_symbol_index]
    data_end = data_start + info.nfft
    if data_start < 0 or data_end > waveform.shape[0]:
        return None
    spectrum = np.fft.fft(waveform[data_start:data_end, :], axis=0) / np.sqrt(info.nfft)
    bins = np.concatenate((np.arange(info.nfft - 31, info.nfft), np.arange(1, 32)))
    observed = spectrum[bins, :]
    best: tuple[int, int, float] | None = None
    for nid1 in range(168):
        sequence0, sequence5 = _sss_sequences(nid1, nid2)
        for subframe, sequence in ((0, sequence0), (5, sequence5)):
            denominator = np.sqrt(62.0 * np.sum(np.abs(observed) ** 2, axis=0))
            score_by_antenna = np.divide(
                np.abs(sequence @ observed),
                denominator,
                out=np.zeros(observed.shape[1]),
                where=denominator > 0,
            )
            score = float(np.max(score_by_antenna))
            if best is None or score > best[2]:
                best = (nid1, subframe, score)
    return best


def _sss_sequences(nid1: int, nid2: int) -> tuple[np.ndarray, np.ndarray]:
    if not 0 <= nid1 < 168 or not 0 <= nid2 < 3:
        raise ValueError("nid1 or nid2 is outside the LTE range")
    s_tilde, c_tilde, z_tilde = _sss_base_sequences()
    q_prime = nid1 // 30
    q = (nid1 + q_prime * (q_prime + 1) // 2) // 30
    m_prime = nid1 + q * (q + 1) // 2
    m0 = m_prime % 31
    m1 = (m0 + m_prime // 31 + 1) % 31
    n = np.arange(31)
    s0 = s_tilde[(n + m0) % 31]
    s1 = s_tilde[(n + m1) % 31]
    c0 = c_tilde[(n + nid2) % 31]
    c1 = c_tilde[(n + nid2 + 3) % 31]
    z0 = z_tilde[(n + (m0 % 8)) % 31]
    z1 = z_tilde[(n + (m1 % 8)) % 31]
    sequence0 = np.empty(62, dtype=float)
    sequence5 = np.empty(62, dtype=float)
    sequence0[0::2] = s0 * c0
    sequence0[1::2] = s1 * c1 * z0
    sequence5[0::2] = s1 * c0
    sequence5[1::2] = s0 * c1 * z1
    return sequence0, sequence5


def _sss_base_sequences() -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    def generate(taps: tuple[int, ...]) -> np.ndarray:
        state = np.zeros(31, dtype=int)
        state[4] = 1
        for index in range(26):
            state[index + 5] = sum(state[index + tap] for tap in taps) % 2
        return 1 - 2 * state

    return generate((2, 0)), generate((3, 0)), generate((4, 2, 1, 0))


def _frame_offset(info: LteOfdmInfo, pss_start: int, subframe: int, enb: Any) -> int:
    subframe_length = _subframe_length(info)
    mode = str(_field(enb, "duplex_mode", "DuplexMode", default="FDD")).lower()
    pss_subframe = subframe if mode != "tdd" else subframe + 1
    frame_offset = pss_start - pss_subframe * subframe_length - info.pss_offset
    frame_length = 10 * subframe_length
    while frame_offset < 0:
        frame_offset += frame_length
    return int(frame_offset)


def _subframe_length(info: LteOfdmInfo) -> int:
    return int(sum(info.nfft + cp for cp in info.cyclic_prefix_lengths))


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


lte_cell_search = cell_search


__all__ = ["CellSearchError", "CellSearchResult", "cell_search", "lte_cell_search"]
