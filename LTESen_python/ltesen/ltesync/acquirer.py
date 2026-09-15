"""Initial LTE cell acquisition and PBCH/MIB lock."""

from __future__ import annotations

from dataclasses import dataclass
from math import ceil, isfinite
from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from ltesen.lteio import IQDataFile, processing_sample_rate, resample_waveform
from ltesen.ltephy.ch_estimation import lte_dl_channel_estimate
from ltesen.ltephy.common import (
    lte_extract_resources,
    lte_ofdm_info,
    lte_resource_grid_size,
)
from ltesen.ltephy.ofdm import lte_ofdm_demodulate
from ltesen.ltephy.phch import lte_mib, lte_pbch_decode, lte_pbch_indices
from ltesen.ltephy.sync import (
    CellSearchError,
    cell_search,
    lte_dl_frame_offset,
    lte_frequency_correct,
    lte_frequency_offset,
)


class AcquisitionError(RuntimeError):
    """Raised when an LTE lock cannot be established."""


@dataclass(frozen=True)
class AcquisitionLock:
    """Immutable lock context shared by the streaming receiver."""

    epoch: int
    enb: dict[str, Any]
    ofdm_info: Any
    raw_sample_rate_hz: float
    reported_raw_sample_rate_hz: float
    lte_sample_rate_hz: float
    raw_frame_start_sample_0: int
    initial_cfo_hz: float
    receive_antenna_count: int
    diagnostics: dict[str, Any]

    def as_dict(self) -> dict[str, Any]:
        """Return a serialization-friendly lock mapping."""

        return {
            "epoch": self.epoch,
            "enb": dict(self.enb),
            "ofdm_info": self.ofdm_info.as_dict(),
            "raw_sample_rate_hz": self.raw_sample_rate_hz,
            "reported_raw_sample_rate_hz": self.reported_raw_sample_rate_hz,
            "lte_sample_rate_hz": self.lte_sample_rate_hz,
            "raw_frame_start_sample_0": self.raw_frame_start_sample_0,
            "initial_cfo_hz": self.initial_cfo_hz,
            "receive_antenna_count": self.receive_antenna_count,
            "diagnostics": dict(self.diagnostics),
        }


class Acquirer:
    """Perform the MATLAB ``ltesync.Acquirer`` flow in Python.

    The acquisition stage searches at the configured initial bandwidth,
    decodes PBCH/MIB, then re-runs CFO and frame timing at the bandwidth
    reported by the MIB.  The current implementation intentionally targets
    FDD; the downstream CRS and CSI path has not yet been generalized to TDD.
    """

    def __init__(self, config: Mapping[str, Any] | None = None) -> None:
        self.config = dict(config or {})

    def acquire(
        self,
        data_file: IQDataFile,
        epoch: int = 1,
        head_start_sample_0: int | None = None,
    ) -> AcquisitionLock:
        """Acquire one cell from a seekable IQ recording."""

        if not hasattr(data_file, "read_at"):
            raise TypeError("data_file must provide a read_at method")
        reported_rate = float(getattr(data_file, "sample_rate", np.nan))
        if not isfinite(reported_rate) or reported_rate <= 0:
            raise AcquisitionError("recording metadata has no valid sample rate")
        raw_rate = processing_sample_rate(reported_rate)
        head_start = self._head_start(head_start_sample_0)
        search_seconds = self._positive_real(
            self.config.get("search_duration_seconds", 0.05),
            "search_duration_seconds",
        )
        search_count = max(1, int(round(search_seconds * raw_rate)))
        sample_count = getattr(data_file, "sample_count", None)
        if sample_count is not None:
            if head_start >= int(sample_count):
                raise AcquisitionError("acquisition head start is beyond the recording")
            search_count = min(search_count, int(sample_count) - head_start)

        head_waveform = np.asarray(
            data_file.read_at(head_start, search_count, normalize=True)
        )
        if head_waveform.size == 0:
            raise AcquisitionError("acquisition waveform is empty")
        if head_waveform.ndim == 1:
            receive_antenna_count = 1
        elif head_waveform.ndim == 2:
            receive_antenna_count = head_waveform.shape[1]
        else:
            raise AcquisitionError("recording reader returned an invalid waveform shape")

        initial_ndlrb = self._positive_int(
            self.config.get("initial_ndlrb", 6), "initial_ndlrb"
        )
        search_base = {
            "ndlrb": initial_ndlrb,
            "cyclic_prefix": "Normal",
            "duplex_mode": "FDD",
        }
        search_info = lte_ofdm_info(search_base)
        search_waveform = resample_waveform(
            head_waveform,
            raw_rate,
            search_info.sampling_rate_hz,
        )
        search_algorithm = {
            "max_cell_count": self._positive_int(
                self.config.get("max_cell_count", 1), "max_cell_count"
            ),
            "sss_detection": self.config.get("sss_detection", "PostFFT"),
        }
        candidates: list[dict[str, Any]] = []
        for prefix in ("Normal", "Extended"):
            candidate_cfg = dict(search_base)
            candidate_cfg["cyclic_prefix"] = prefix
            try:
                cell_ids, offsets, peaks = cell_search(
                    candidate_cfg, search_waveform, search_algorithm
                )
            except (CellSearchError, ValueError, NotImplementedError):
                continue
            for cell_id, offset, peak in zip(cell_ids, offsets, peaks):
                candidates.append(
                    {
                        "cell_id": int(cell_id),
                        "offset": int(offset),
                        "peak": float(peak),
                        "cyclic_prefix": prefix,
                        "duplex_mode": "FDD",
                    }
                )
        if not candidates:
            raise AcquisitionError("LTE PSS/SSS cell search did not find a valid cell")
        candidates.sort(key=lambda item: item["peak"], reverse=True)
        selected = candidates[0]

        search_enb = {
            "ndlrb": initial_ndlrb,
            "ncellid": selected["cell_id"],
            "cyclic_prefix": selected["cyclic_prefix"],
            "duplex_mode": selected["duplex_mode"],
            "nsubframe": 0,
            "cell_ref_p": 4,
        }
        search_offset = selected["offset"]
        synchronized = search_waveform[search_offset:]
        if synchronized.size == 0:
            raise AcquisitionError("cell-search timing leaves no waveform")
        search_cfo = lte_frequency_offset(search_enb, synchronized)
        corrected_search = lte_frequency_correct(search_enb, synchronized, search_cfo)
        search_grid = lte_ofdm_demodulate(search_enb, corrected_search, cp_fraction=0.55)
        _, symbols_per_subframe, _ = self._grid_size(search_enb)
        if search_grid.shape[1] < symbols_per_subframe:
            raise AcquisitionError("synchronized acquisition signal is too short")
        search_grid = search_grid[:, :symbols_per_subframe, :]

        cec = self.config.get(
            "channel_estimator",
            {
                "pilot_average": "UserDefined",
                "freq_window": 13,
                "time_window": 9,
                "interp_type": "linear",
            },
        )
        hest, noise_estimate = lte_dl_channel_estimate(search_enb, search_grid, cec)
        pbch_indices = lte_pbch_indices(search_enb)
        pbch_rx, pbch_hest = lte_extract_resources(
            pbch_indices, search_grid, hest
        )
        _, _, frame_modulo4, mib, detected_ports = lte_pbch_decode(
            search_enb,
            pbch_rx,
            pbch_hest,
            noise_estimate=noise_estimate,
        )
        if detected_ports == 0:
            raise AcquisitionError("PBCH/MIB decoding failed during acquisition")
        enb = lte_mib(mib, search_enb)
        if enb.get("ndlrb", 0) == 0:
            raise AcquisitionError("MIB reported an unsupported downlink bandwidth")
        enb["nframe"] = (int(enb.get("nframe", 0)) + int(frame_modulo4)) % 1024
        enb["cell_ref_p"] = int(detected_ports)

        ofdm_info = lte_ofdm_info(enb)
        full_band_waveform = resample_waveform(
            head_waveform,
            raw_rate,
            ofdm_info.sampling_rate_hz,
        )
        initial_cfo = lte_frequency_offset(enb, full_band_waveform)
        corrected_full_band = lte_frequency_correct(
            enb, full_band_waveform, initial_cfo
        )
        frame_timing = self.config.get("frame_timing", {})
        frame_offset_lte = lte_dl_frame_offset(
            enb, corrected_full_band, frame_timing
        )
        frame_offset_raw = int(
            round(frame_offset_lte * raw_rate / ofdm_info.sampling_rate_hz)
        )
        raw_frame_start = head_start + frame_offset_raw
        if raw_frame_start < 0:
            raise AcquisitionError("frame timing points before the recording")

        diagnostics = {
            "cell_search_candidates": tuple(candidates),
            "selected_cell_search_peak": selected["peak"],
            "search_offset_samples": search_offset,
            "search_cfo_hz": float(search_cfo),
            "frame_offset_lte_samples": int(frame_offset_lte),
            "frame_offset_raw_samples": frame_offset_raw,
            "noise_estimate": float(noise_estimate),
            "frame_modulo4": int(frame_modulo4),
        }
        return AcquisitionLock(
            epoch=int(epoch),
            enb=dict(enb),
            ofdm_info=ofdm_info,
            raw_sample_rate_hz=float(raw_rate),
            reported_raw_sample_rate_hz=reported_rate,
            lte_sample_rate_hz=float(ofdm_info.sampling_rate_hz),
            raw_frame_start_sample_0=raw_frame_start,
            initial_cfo_hz=float(initial_cfo),
            receive_antenna_count=receive_antenna_count,
            diagnostics=diagnostics,
        )

    def _head_start(self, value: int | None) -> int:
        raw = self.config.get("head_start_sample", 3_072_000) if value is None else value
        return self._nonnegative_int(raw, "head_start_sample")

    @staticmethod
    def _positive_int(value: Any, name: str) -> int:
        if isinstance(value, bool) or not isinstance(value, Integral) or int(value) <= 0:
            raise ValueError(f"{name} must be a positive integer")
        return int(value)

    @staticmethod
    def _nonnegative_int(value: Any, name: str) -> int:
        if isinstance(value, bool) or not isinstance(value, Integral) or int(value) < 0:
            raise ValueError(f"{name} must be a non-negative integer")
        return int(value)

    @staticmethod
    def _positive_real(value: Any, name: str) -> float:
        if isinstance(value, bool) or not isinstance(value, Real) or not np.isfinite(value) or value <= 0:
            raise ValueError(f"{name} must be positive and finite")
        return float(value)

    @staticmethod
    def _grid_size(enb: Mapping[str, Any]) -> tuple[int, int, int]:
        return lte_resource_grid_size(enb)


__all__ = ["AcquisitionError", "AcquisitionLock", "Acquirer"]
