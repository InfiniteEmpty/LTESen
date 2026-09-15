"""Streaming LTE receiver source for the Python pipeline."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from ..lteio import IQDataFile, resample_waveform
from ltesen.ltephy.ch_estimation import CrsReferenceCache, lte_crs_csi
from ltesen.ltephy.ofdm import OfdmPlan, build_ofdm_plan, lte_ofdm_demodulate
from ..ltepipe import Message, Module, Packet, Result
from ..ltesync import (
    Acquirer,
    AcquisitionError,
    AcquisitionLock,
    SyncSupervisor,
    Timebase,
)
from .cfo import CfoTracker
from .csi_tracker import CsiTracker


LTE_SUBFRAMES_PER_FRAME = 10


class Receiver(Module):
    """Source module that emits one CSI packet per LTE frame.

    The receiver owns acquisition, raw/LTE sample conversion, CFO refinement,
    frame-batched OFDM demodulation, CRS extraction, CSI phase/SFO tracking,
    and timing health monitoring. Continuous CFO and phase/SFO correction is
    retained for every subframe, while the static CSI reference and its
    discrete integer timing correction are updated once per LTE frame.
    Cancellation remains a later module.
    """

    def __init__(
        self,
        data_file: IQDataFile,
        config: Mapping[str, Any] | None = None,
    ) -> None:
        super().__init__("receiver", "", "csi-frame")
        if not hasattr(data_file, "read_at"):
            raise TypeError("data_file must provide a read_at method")
        self.data_file = data_file
        self.config = dict(config or {})
        self.acquirer = Acquirer(self.config.get("acquisition", self.config))
        self.lock: AcquisitionLock | None = None
        self.timebase: Timebase | None = None
        self.cfo_tracker: CfoTracker | None = None
        self.csi_tracker: CsiTracker | None = None
        self.ofdm_plan: OfdmPlan | None = None
        self.sync_supervisor = SyncSupervisor(self.config.get("sync", {}))
        self.enb: dict[str, Any] | None = None
        self.crs_reference_cache: CrsReferenceCache | None = None
        self.receive_indices: tuple[int, ...] = ()
        self.sample_count = 0
        self.frame_count = 0
        self.end_of_file = False
        self._frame_sample_shift_sum = 0.0
        self._frame_sample_shift_count = 0
        self.last_frame_sample_shift = float("nan")
        self.last_frame_timing_delta_lte_samples = 0

    def initialize(self, runtime: Any) -> None:
        super().initialize(runtime)
        if self.lock is not None:
            return
        acquisition = self.config.get("acquisition", {})
        self.lock = self.acquirer.acquire(
            self.data_file,
            epoch=1,
            head_start_sample_0=acquisition.get("head_start_sample"),
        )
        self._configure_from_lock(self.lock)
        if self.runtime is not None:
            self.runtime.set_context("lte", self._runtime_lock_context())

    def process(self, message: Message) -> Result:
        self.validate_input(message)
        if message.has_packet:
            raise ValueError("the receiver source does not accept an input packet")
        if self.lock is None or self.timebase is None or self.enb is None:
            raise RuntimeError("receiver has not been initialized")
        sample_count = getattr(self.data_file, "sample_count", None)
        if sample_count is None:
            raise ValueError("receiver requires a recording with a known sample count")
        if not self.timebase.can_read(int(sample_count)):
            self.end_of_file = True
            return Result.stop(Message.none(), "end-of-file")

        return self._process_frame(int(sample_count))

    def _process_frame(self, sample_count: int) -> Result:
        assert self.lock is not None
        assert self.timebase is not None
        assert self.enb is not None
        assert self.cfo_tracker is not None
        tracking = self.config.get("tracking", {})
        corrected_subframes: list[np.ndarray] = []
        subframe_metadata: list[dict[str, Any]] = []
        cfo_qualities: list[dict[str, Any]] = []

        for subframe_index in range(LTE_SUBFRAMES_PER_FRAME):
            if not self.timebase.can_read(sample_count):
                # Do not emit an incomplete final frame.
                self.end_of_file = True
                return Result.stop(Message.none(), "end-of-file")

            meta = self.timebase.current_meta()
            if int(meta["subframe_number"]) != subframe_index:
                raise AcquisitionError(
                    "receiver frame processing lost the LTE subframe boundary"
                )
            raw = self.data_file.read_at(
                meta["raw_start_sample_0"],
                meta["raw_sample_count"],
                normalize=False,
            )
            raw = _as_waveform(raw)
            raw = raw[:, self.receive_indices]
            waveform = resample_waveform(
                raw,
                self.lock.raw_sample_rate_hz,
                self.lock.lte_sample_rate_hz,
                output_length=int(round(self.lock.lte_sample_rate_hz / 1000.0)),
            )
            corrected, cfo_quality = self.cfo_tracker.correct(waveform)
            corrected_subframes.append(corrected)
            subframe_metadata.append(meta)
            cfo_qualities.append(cfo_quality)

            sync_event = self.sync_supervisor.observe(
                cfo_quality["cp_correlation"], meta
            )
            if sync_event["available"]:
                return self._reacquire(sync_event)

            # Keep the timebase and per-subframe CFO state chronological, but
            # defer the integer SFO correction until the completed frame.
            self.timebase.advance()

        frame_waveform = np.concatenate(corrected_subframes, axis=0)
        frame_enb = dict(self.enb)
        frame_enb["nframe"] = int(subframe_metadata[0]["frame_number"])
        frame_enb["nsubframe"] = 0
        assert self.ofdm_plan is not None
        grid = lte_ofdm_demodulate(
            frame_enb,
            frame_waveform,
            cp_fraction=float(tracking.get("cp_fraction", 0.55)),
            plan=self.ofdm_plan,
        )
        expected_symbols = len(self.lock.ofdm_info.cyclic_prefix_lengths)
        expected_frame_symbols = expected_symbols * LTE_SUBFRAMES_PER_FRAME
        if grid.shape[1] < expected_frame_symbols:
            raise AcquisitionError("OFDM demodulation did not produce a full LTE frame")
        grid = grid[:, :expected_frame_symbols, :]

        assert self.crs_reference_cache is not None
        g1_parts: list[np.ndarray] = []
        g2_parts: list[np.ndarray] = []
        index_g1: np.ndarray | None = None
        index_g2: np.ndarray | None = None
        for subframe_index in range(LTE_SUBFRAMES_PER_FRAME):
            frame_enb["nsubframe"] = subframe_index
            subframe_grid = grid[
                :,
                subframe_index * expected_symbols : (subframe_index + 1) * expected_symbols,
                :,
            ]
            g1, g2, current_index_g1, current_index_g2 = lte_crs_csi(
                frame_enb,
                subframe_grid,
                reference_cache=self.crs_reference_cache,
            )
            g1_parts.append(g1)
            g2_parts.append(g2)
            if index_g1 is None:
                index_g1 = current_index_g1
                index_g2 = current_index_g2
            elif not (
                np.array_equal(index_g1, current_index_g1)
                and np.array_equal(index_g2, current_index_g2)
            ):
                raise AcquisitionError("CRS carrier locations changed within an LTE frame")

        assert index_g1 is not None
        assert index_g2 is not None
        assert self.csi_tracker is not None
        tracked_data, tracking_quality = self.csi_tracker.correct_frame(
            np.concatenate(g1_parts, axis=1),
            np.concatenate(g2_parts, axis=1),
            index_g1,
            index_g2,
        )
        self._accumulate_frame_sample_shift(tracking_quality.get("sample_shift"))
        self._apply_frame_timing_correction()

        first_meta = subframe_metadata[0]
        last_meta = subframe_metadata[-1]
        packet_meta = dict(first_meta)
        packet_meta.update(
            {
                "ncellid": frame_enb["ncellid"],
                "ndlrb": frame_enb["ndlrb"],
                "cell_ref_p": frame_enb["cell_ref_p"],
                "cyclic_prefix": frame_enb["cyclic_prefix"],
                "raw_end_sample_0": last_meta["raw_end_sample_0"],
                "end_sequence": last_meta["sequence"],
            }
        )
        packet_meta.pop("subframe_number", None)
        packet = Packet(
            type="csi-frame",
            data=tracked_data,
            meta=packet_meta,
            quality={
                "cfo": _aggregate_cfo_quality(cfo_qualities),
                "tracking": tracking_quality,
                "complete": True,
                "subframe_count": LTE_SUBFRAMES_PER_FRAME,
            },
        )
        self.sample_count += LTE_SUBFRAMES_PER_FRAME
        self.frame_count += 1
        return Result.emit(packet)

    def get_status(self) -> dict[str, Any]:
        return {
            "state": "ready" if self.lock is not None else "cold",
            "ready": self.lock is not None,
            "epoch": self.lock.epoch if self.lock is not None else None,
            "sample_count": self.sample_count,
            "frame_count": self.frame_count,
            "end_of_file": self.end_of_file,
            "lock": self.lock.as_dict() if self.lock is not None else None,
            "cfo": self.cfo_tracker.get_status() if self.cfo_tracker else None,
            "csi": self.csi_tracker.get_status() if self.csi_tracker else None,
            "sfo": {
                "last_frame_sample_shift": self.last_frame_sample_shift,
                "last_frame_timing_delta_lte_samples": self.last_frame_timing_delta_lte_samples,
                "pending_subframes": self._frame_sample_shift_count,
            },
            "sync": self.sync_supervisor.get_status(),
        }

    def _configure_from_lock(self, lock: AcquisitionLock) -> None:
        enb = dict(lock.enb)
        tracking = self.config.get("tracking", {})
        maximum_ports = int(tracking.get("maximum_tx_ports", enb["cell_ref_p"]))
        if maximum_ports not in {1, 2, 4}:
            raise ValueError("maximum_tx_ports must be one of 1, 2, or 4")
        enb["cell_ref_p"] = min(int(enb["cell_ref_p"]), maximum_ports)
        if enb["cell_ref_p"] > 2:
            raise NotImplementedError(
                "the streaming CSI extractor currently supports at most two transmit ports"
            )
        self.crs_reference_cache = CrsReferenceCache(enb)
        available = int(getattr(self.data_file, "num_channels", 1))
        self.receive_indices = _antenna_indices(
            tracking.get("receive_antenna_indices", [1]), available
        )
        self.enb = enb
        self.csi_tracker = CsiTracker(
            tracking,
            {
                "enb": enb,
                "ofdm_info": lock.ofdm_info,
                "receive_antenna_count": len(self.receive_indices),
            },
        )
        self.timebase = Timebase({**lock.as_dict(), "enb": enb})
        self.cfo_tracker = CfoTracker(tracking, lock)
        self._frame_sample_shift_sum = 0.0
        self._frame_sample_shift_count = 0
        self.last_frame_sample_shift = float("nan")
        self.last_frame_timing_delta_lte_samples = 0
        self.ofdm_plan = build_ofdm_plan(
            lock.ofdm_info,
            int(enb["ndlrb"]),
            cp_fraction=float(tracking.get("cp_fraction", 0.55)),
            sample_count=int(round(lock.lte_sample_rate_hz / 1000.0))
            * LTE_SUBFRAMES_PER_FRAME,
        )
        self.sync_supervisor.reset()

    def _accumulate_frame_sample_shift(self, sample_shift: Any) -> None:
        if sample_shift is None:
            return
        shift = float(sample_shift)
        if not np.isfinite(shift):
            return
        self._frame_sample_shift_sum += shift
        self._frame_sample_shift_count += 1

    def _apply_frame_timing_correction(self) -> None:
        if self._frame_sample_shift_count:
            mean_shift = (
                self._frame_sample_shift_sum / self._frame_sample_shift_count
            )
            timing_delta = -int(np.rint(mean_shift))
        else:
            mean_shift = float("nan")
            timing_delta = 0
        assert self.timebase is not None
        self.timebase.apply_timing_correction(timing_delta)
        self.last_frame_sample_shift = mean_shift
        self.last_frame_timing_delta_lte_samples = timing_delta
        self._frame_sample_shift_sum = 0.0
        self._frame_sample_shift_count = 0

    def _reacquire(self, event: Mapping[str, Any]) -> Result:
        if self.lock is None:
            raise RuntimeError("cannot reacquire before initial acquisition")
        payload = event.get("payload", {})
        expected = payload.get("expected_raw_sample_0")
        if expected is None:
            raise ValueError("reacquisition event lacks expected_raw_sample_0")
        search_start = max(
            0,
            int(expected)
            - int(round(0.005 * self.lock.raw_sample_rate_hz)),
        )
        self.lock = self.acquirer.acquire(
            self.data_file,
            epoch=self.lock.epoch + 1,
            head_start_sample_0=search_start,
        )
        self._configure_from_lock(self.lock)
        if self.runtime is not None:
            self.runtime.set_context("lte", self._runtime_lock_context())
        return Result.reset_downstream(
            Message.none(),
            self.lock.epoch,
            str(payload.get("reason", "reacquisition")),
        )

    def _runtime_lock_context(self) -> dict[str, Any]:
        assert self.lock is not None
        context = self.lock.as_dict()
        center_frequency = getattr(self.data_file, "frequency", np.nan)
        if np.isfinite(center_frequency) and center_frequency > 0:
            context["center_frequency_hz"] = float(center_frequency)
        return context


def _as_waveform(value: np.ndarray) -> np.ndarray:
    array = np.asarray(value)
    if array.ndim == 1:
        array = array[:, None]
    if array.ndim != 2 or array.shape[1] == 0:
        raise ValueError("recording reader must return (samples, antennas)")
    return array.astype(np.complex64, copy=False)


def _aggregate_cfo_quality(qualities: list[dict[str, Any]]) -> dict[str, Any]:
    if not qualities:
        return {}
    result = dict(qualities[-1])
    correlations = [
        float(item["cp_correlation"])
        for item in qualities
        if "cp_correlation" in item and np.isfinite(item["cp_correlation"])
    ]
    if correlations:
        result["cp_correlation"] = float(np.mean(correlations))
        result["cp_correlation_min"] = float(np.min(correlations))
    result["subframe_count"] = len(qualities)
    return result


def _antenna_indices(value: Any, available: int) -> tuple[int, ...]:
    if isinstance(value, (int, np.integer)) and not isinstance(value, bool):
        values = (int(value),)
    else:
        values = tuple(int(item) for item in value)
    if not values:
        raise ValueError("receive_antenna_indices must not be empty")
    # The checked-in YAML mirrors MATLAB's one-based antenna field.  A zero
    # explicitly selects Python's zero-based convention for custom configs.
    if min(values) >= 1:
        values = tuple(item - 1 for item in values)
    if any(item < 0 or item >= available for item in values):
        raise IndexError("receive_antenna_indices contains an unavailable antenna")
    return values


__all__ = ["Receiver"]
