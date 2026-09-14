"""Streaming LTE receiver source for the Python pipeline."""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from ..lteio import IQDataFile, resample_waveform
from ..ltephy.csi import CrsReferenceCache, lte_crs_csi
from ..ltephy.ofdm_demodulate import lte_ofdm_demodulate
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


class Receiver(Module):
    """Source module that emits one CSI packet per LTE subframe.

    The receiver owns acquisition, raw/LTE sample conversion, CFO refinement,
    OFDM demodulation, CRS extraction, CSI phase/SFO tracking, and timing
    health monitoring. Cancellation remains a later module.
    """

    def __init__(
        self,
        data_file: IQDataFile,
        config: Mapping[str, Any] | None = None,
    ) -> None:
        super().__init__("receiver", "", "csi-subframe")
        if not hasattr(data_file, "read_at"):
            raise TypeError("data_file must provide a read_at method")
        self.data_file = data_file
        self.config = dict(config or {})
        self.acquirer = Acquirer(self.config.get("acquisition", self.config))
        self.lock: AcquisitionLock | None = None
        self.timebase: Timebase | None = None
        self.cfo_tracker: CfoTracker | None = None
        self.csi_tracker: CsiTracker | None = None
        self.sync_supervisor = SyncSupervisor(self.config.get("sync", {}))
        self.enb: dict[str, Any] | None = None
        self.crs_reference_cache: CrsReferenceCache | None = None
        self.receive_indices: tuple[int, ...] = ()
        self.sample_count = 0
        self.end_of_file = False

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

        meta = self.timebase.current_meta()
        raw = self.data_file.read_at(
            meta["raw_start_sample_0"],
            meta["raw_sample_count"],
            normalize=False,
        )
        raw = _as_waveform(raw)
        raw = raw[:, self.receive_indices]
        tracking = self.config.get("tracking", {})
        waveform = resample_waveform(
            raw,
            self.lock.raw_sample_rate_hz,
            self.lock.lte_sample_rate_hz,
            output_length=int(round(self.lock.lte_sample_rate_hz / 1000.0)),
        )
        assert self.cfo_tracker is not None
        corrected, cfo_quality = self.cfo_tracker.correct(waveform)

        frame_enb = dict(self.enb)
        frame_enb["nframe"] = int(meta["frame_number"])
        frame_enb["nsubframe"] = int(meta["subframe_number"])
        grid = lte_ofdm_demodulate(
            frame_enb,
            corrected,
            cp_fraction=float(tracking.get("cp_fraction", 0.55)),
        )
        expected_symbols = len(self.lock.ofdm_info.cyclic_prefix_lengths)
        if grid.shape[1] < expected_symbols:
            raise AcquisitionError("OFDM demodulation did not produce a full subframe")
        grid = grid[:, :expected_symbols, :]
        assert self.crs_reference_cache is not None
        g1, g2, index_g1, index_g2 = lte_crs_csi(
            frame_enb,
            grid,
            reference_cache=self.crs_reference_cache,
        )
        assert self.csi_tracker is not None
        tracked_data, tracking_quality = self.csi_tracker.correct(
            g1, g2, index_g1, index_g2
        )

        packet_meta = dict(meta)
        packet_meta.update(
            {
                "ncellid": frame_enb["ncellid"],
                "ndlrb": frame_enb["ndlrb"],
                "cell_ref_p": frame_enb["cell_ref_p"],
                "cyclic_prefix": frame_enb["cyclic_prefix"],
            }
        )
        packet = Packet(
            type="csi-subframe",
            data=tracked_data,
            meta=packet_meta,
            quality={"cfo": cfo_quality, "tracking": tracking_quality},
        )
        sync_event = self.sync_supervisor.observe(
            cfo_quality["cp_correlation"], packet_meta
        )
        if sync_event["available"]:
            return self._reacquire(sync_event)
        self.timebase.advance(tracking_quality["timing_delta_lte_samples"])
        self.sample_count += 1
        return Result.emit(packet)

    def get_status(self) -> dict[str, Any]:
        return {
            "state": "ready" if self.lock is not None else "cold",
            "ready": self.lock is not None,
            "epoch": self.lock.epoch if self.lock is not None else None,
            "sample_count": self.sample_count,
            "end_of_file": self.end_of_file,
            "lock": self.lock.as_dict() if self.lock is not None else None,
            "cfo": self.cfo_tracker.get_status() if self.cfo_tracker else None,
            "csi": self.csi_tracker.get_status() if self.csi_tracker else None,
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
        self.sync_supervisor.reset()

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
    return array.astype(np.complex128, copy=False)


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
