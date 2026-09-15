"""Windowed 2-D FFT range-Doppler processing for CSI frames."""

from __future__ import annotations

import math
from numbers import Integral, Real
from typing import Any, Mapping

import numpy as np

from ..ltebuffer import FrameWindow
from ..ltebuffer._array_shapes import as_csi_4d
from ..ltepipe import Message, Module, Packet, Result, Runtime


class RangeDopplerProcessor(Module):
    """Build CSI windows and emit a physical-axis range-Doppler map.

    The implementation follows ``lterd.Processor`` in the MATLAB project:
    Hamming windows are applied in frequency and slow time, followed by an
    IFFT over CRS subcarriers and an FFT over the slow-time samples.  The
    processor accepts complete ``csi-frame`` packets. The streaming receiver
    builds those packets directly, so frame assembly is not a separate runtime
    stage.
    """

    def __init__(
        self,
        config: Mapping[str, Any] | None = None,
        *,
        context: Mapping[str, Any] | None = None,
    ) -> None:
        super().__init__("range_doppler", "csi-frame", "range-doppler")
        self.config = dict(config or {})
        window_frames = _positive_int(
            self.config.get("window_frames", 10), "window_frames"
        )
        hop_frames = _positive_int(self.config.get("hop_frames", 10), "hop_frames")
        self.window = FrameWindow(window_frames, hop_frames)
        self.context = dict(context) if context is not None else None
        self.epoch: int | float | None = None
        self.output_count = 0
        self.noise_floor_db = float("nan")

    def initialize(self, runtime: Runtime) -> None:
        super().initialize(runtime)
        if self.context is None:
            self.context = dict(runtime.get_context("lte"))
        # Fail early, before the first complete window arrives, when the
        # physical center frequency needed for the velocity axis is absent.
        _processing_context(self.context, self.config)

    def process(self, message: Message) -> Result:
        self.validate_input(message)
        if not message.has_packet:
            return Result.forward(message)
        assert message.packet is not None
        packet = message.packet

        if _require_cancellation_ready(self.config) and not _is_cancellation_ready(
            packet.quality, packet.meta
        ):
            return Result.forward(message.clear_packet())

        meta = _normalise_frame_metadata(packet.meta)
        if not _same_epoch(self.epoch, meta["epoch"]):
            self.reset({"epoch": meta["epoch"], "reason": "new-epoch"})

        window_result = self.window.push(packet, self.config.get("group", "g1"))
        empty = Result.forward(message.clear_packet())
        if not window_result.available:
            return empty
        assert window_result.data is not None
        csi = _select_antennas(
            window_result.data,
            receive_antenna=self.config.get("receive_antenna", 1),
            transmit_antenna=self.config.get("transmit_antenna", 1),
        )
        assert self.context is not None
        data, quality = compute_range_doppler(
            csi,
            context=self.context,
            config=self.config,
            noise_floor_db=self.noise_floor_db,
        )
        self.noise_floor_db = quality["noise_floor_db"]

        output_meta = dict(window_result.first_meta)
        output_meta.update(
            {
                "raw_end_sample_0": window_result.last_meta["raw_end_sample_0"],
                "end_sequence": window_result.last_meta["end_sequence"],
                "window_frames": self.window.window_frames,
                "hop_frames": self.window.hop_frames,
            }
        )
        output_packet = Packet(
            type="range-doppler",
            data=data,
            meta=output_meta,
            quality=quality,
        )
        self.output_count += 1
        return Result.forward(self.replace_output(empty.message, output_packet))

    def reset(self, event: Any = None) -> None:
        epoch: int | float | None = None
        reason = "reset"
        if isinstance(event, Mapping):
            epoch = event.get("epoch", event.get("Epoch"))
            reason = str(event.get("reason", event.get("Reason", reason)))
        elif event is not None:
            epoch = event
        self.epoch = epoch
        self.noise_floor_db = float("nan")
        self.window.reset(epoch, reason)

    def get_status(self) -> dict[str, Any]:
        return {
            "state": "ready" if self.context is not None else "cold",
            "ready": self.context is not None,
            "epoch": self.epoch,
            "output_count": self.output_count,
            "buffered_frames": self.window.count,
            "noise_floor_db": self.noise_floor_db,
        }


def compute_range_doppler(
    csi: np.ndarray,
    *,
    context: Mapping[str, Any],
    config: Mapping[str, Any] | None = None,
    noise_floor_db: float = float("nan"),
) -> tuple[dict[str, np.ndarray], dict[str, Any]]:
    """Compute a windowed CSI range-Doppler map.

    ``csi`` is a two-dimensional array with shape ``(crs, slow_time)``.
    The returned map uses the same convention as the MATLAB processor:
    range is the first axis and velocity is the second axis.  The velocity
    axis is descending because positive radial velocity corresponds to the
    negative slow-time frequency under the LTE bistatic phase convention.
    """

    values = np.asarray(csi, dtype=np.complex128)
    if values.ndim != 2 or min(values.shape) <= 0:
        raise ValueError("csi must be a non-empty two-dimensional array")
    if not np.all(np.isfinite(values)):
        raise ValueError("csi must contain finite values")

    cfg = dict(config or {})
    nfft, sample_rate_hz, center_frequency_hz = _processing_context(context, cfg)
    crs_spacing = _positive_real(cfg.get("crs_spacing", 6), "crs_spacing")
    slow_time_period = _positive_real(
        cfg.get("slow_time_sample_period_seconds", 5e-4),
        "slow_time_sample_period_seconds",
    )
    speed_of_light = _positive_real(
        cfg.get("speed_of_light_meters_per_second", 299792458.0),
        "speed_of_light_meters_per_second",
    )

    crs_count, slow_time_count = values.shape
    frequency_window = np.hamming(crs_count)
    time_window = np.hamming(slow_time_count)
    windowed = values * frequency_window[:, None] * time_window[None, :]
    cir = np.fft.fftshift(np.fft.ifft(windowed, axis=0), axes=0)
    rd_map = np.fft.fftshift(np.fft.fft(cir, axis=1), axes=1)
    magnitude_db = 20.0 * np.log10(np.abs(rd_map) + 1e-6)

    range_resolution = speed_of_light / (
        (sample_rate_hz / nfft) * crs_spacing
    ) / (2.0 * crs_count)
    range_axis = (
        np.arange(-crs_count // 2, (-crs_count // 2) + crs_count, dtype=float)
        * range_resolution
    )
    doppler_axis_hz = np.fft.fftshift(
        np.fft.fftfreq(slow_time_count, d=slow_time_period)
    )
    velocity_axis = -speed_of_light / (2.0 * center_frequency_hz) * doppler_axis_hz

    if not np.isfinite(noise_floor_db):
        quantile = _real_in_range(
            cfg.get("noise_floor_quantile", 0.10),
            "noise_floor_quantile",
            0.0,
            1.0,
        )
        sorted_magnitude = np.sort(magnitude_db.reshape(-1))
        position = max(
            0,
            min(
                sorted_magnitude.size - 1,
                int(np.floor(quantile * sorted_magnitude.size + 0.5)) - 1,
            ),
        )
        noise_floor_db = float(sorted_magnitude[position])
    else:
        noise_floor_db = float(noise_floor_db)

    display_below = _nonnegative_real(
        cfg.get("display_below_noise_db", 10), "display_below_noise_db"
    )
    display_above = _nonnegative_real(
        cfg.get("display_above_noise_db", 40), "display_above_noise_db"
    )
    data = {
        "complex_map": rd_map,
        "magnitude_db": magnitude_db,
        "range_meters": range_axis,
        "velocity_meters_per_second": velocity_axis,
    }
    quality = {
        "noise_floor_db": noise_floor_db,
        "display_limits_db": np.asarray(
            [noise_floor_db - display_below, noise_floor_db + display_above],
            dtype=float,
        ),
        "range_resolution_meters": float(range_resolution),
        "velocity_resolution_meters_per_second": float(
            abs(velocity_axis[1] - velocity_axis[0])
            if velocity_axis.size > 1
            else 0.0
        ),
    }
    return data, quality


def _processing_context(
    context: Mapping[str, Any], config: Mapping[str, Any]
) -> tuple[int, float, float]:
    enb = _field(context, "enb", "Enb", default={})
    info = _field(context, "ofdm_info", "OfdmInfo", default={})
    nfft = _positive_int(_field(info, "nfft", "Nfft"), "nfft")
    sample_rate = _positive_real(
        _field(context, "lte_sample_rate_hz", "LteSampleRateHz"),
        "lte_sample_rate_hz",
    )
    center_frequency = _field(
        config,
        "center_frequency_hz",
        "CenterFrequencyHz",
        default=None,
    )
    if center_frequency is None:
        center_frequency = _field(
            context,
            "center_frequency_hz",
            "CenterFrequencyHz",
            "frequency_hz",
            "FrequencyHz",
            default=None,
        )
    if center_frequency is None:
        raise ValueError(
            "range-Doppler processing requires center_frequency_hz in the "
            "recording/runtime context or range_doppler configuration"
        )
    return nfft, sample_rate, _positive_real(
        center_frequency, "center_frequency_hz"
    )


def _select_antennas(
    value: np.ndarray,
    *,
    receive_antenna: Any,
    transmit_antenna: Any,
) -> np.ndarray:
    array = as_csi_4d(value, name="frame window")
    receive_index = _axis_index(receive_antenna, array.shape[2], "receive_antenna")
    transmit_index = _axis_index(transmit_antenna, array.shape[3], "transmit_antenna")
    return np.asarray(array[:, :, receive_index, transmit_index], dtype=np.complex128)


def _axis_index(value: Any, size: int, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, Integral):
        raise ValueError(f"{name} must be an integer antenna index")
    index = int(value)
    # Configuration mirrors MATLAB's one-based antenna numbering.  Zero is
    # accepted as an explicit Python-style index for custom experiments.
    if index >= 1:
        index -= 1
    if index < 0 or index >= size:
        raise IndexError(f"{name} is outside the available antenna planes")
    return index


def _normalise_frame_metadata(metadata: Mapping[str, Any]) -> dict[str, Any]:
    aliases = {
        "epoch": "Epoch",
        "sequence": "Sequence",
        "end_sequence": "EndSequence",
        "raw_end_sample_0": "RawEndSample0",
    }
    result: dict[str, Any] = {}
    for python_name, matlab_name in aliases.items():
        if python_name in metadata:
            result[python_name] = metadata[python_name]
        elif matlab_name in metadata:
            result[python_name] = metadata[matlab_name]
        else:
            raise ValueError("CSI frame metadata is incomplete")
    result.update(metadata)
    return result


def _is_cancellation_ready(quality: Mapping[str, Any], meta: Mapping[str, Any]) -> bool:
    for mapping in (meta, quality):
        for key in ("cancellation_ready", "CancellationReady"):
            if key in mapping:
                return bool(mapping[key])
    return False


def _require_cancellation_ready(config: Mapping[str, Any]) -> bool:
    return bool(
        config.get(
            "require_cancellation_ready",
            config.get("RequireCancellationReady", False),
        )
    )


def _field(value: Any, *names: str, default: Any = ...,) -> Any:
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
    raise ValueError(f"Missing field; expected one of {names}")


def _same_epoch(left: Any, right: Any) -> bool:
    if left == right:
        return True
    return (
        isinstance(left, (float, np.floating))
        and isinstance(right, (float, np.floating))
        and math.isnan(left)
        and math.isnan(right)
    )


def _positive_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, Integral) or int(value) <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return int(value)


def _positive_real(value: Any, name: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, Real)
        or not np.isfinite(value)
        or value <= 0
    ):
        raise ValueError(f"{name} must be positive and finite")
    return float(value)


def _nonnegative_real(value: Any, name: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, Real)
        or not np.isfinite(value)
        or value < 0
    ):
        raise ValueError(f"{name} must be non-negative and finite")
    return float(value)


def _real_in_range(value: Any, name: str, lower: float, upper: float) -> float:
    number = _nonnegative_real(value, name)
    if number < lower or number > upper:
        raise ValueError(f"{name} must be in [{lower}, {upper}]")
    return number


__all__ = ["RangeDopplerProcessor", "compute_range_doppler"]
