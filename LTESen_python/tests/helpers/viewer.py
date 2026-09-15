"""Optional Matplotlib viewer for range-Doppler packets."""

from __future__ import annotations

import multiprocessing as mp
import queue
import time
import traceback
from pathlib import Path
from typing import Any, Mapping

import numpy as np

from ltesen.ltepipe import Message, Module, Packet, Result


class RangeDopplerViewer(Module):
    """Render range-Doppler packets while passing them downstream unchanged."""

    def __init__(self, config: Mapping[str, Any] | None = None) -> None:
        super().__init__("range_doppler_viewer", "range-doppler", "range-doppler")
        self.config = dict(config or {})
        self.enabled = bool(self.config.get("enabled", True))
        self.figure: Any = None
        self.axes: Any = None
        self.image: Any = None
        self.colorbar: Any = None
        self.update_count = 0

    def process(self, message: Message) -> Result:
        self.validate_input(message)
        if self.enabled and self.figure is not None and not self._figure_exists():
            return Result.stop(message, "user-stopped")
        if not message.has_packet or not self.enabled:
            return Result.forward(message)
        assert message.packet is not None
        self._render(message.packet)
        self.update_count += 1
        return Result.forward(message)

    def save(self, path: str | Path) -> Path:
        """Save the current map to an image file."""

        if self.figure is None or not self._figure_exists():
            raise RuntimeError("the range-Doppler viewer has not rendered a packet")
        output = Path(path)
        output.parent.mkdir(parents=True, exist_ok=True)
        self.figure.savefig(output, dpi=150, bbox_inches="tight")
        return output

    def close(self) -> None:
        if self.figure is None:
            return
        import matplotlib.pyplot as plt

        plt.close(self.figure)
        self.figure = None
        self.axes = None
        self.image = None
        self.colorbar = None

    def get_status(self) -> dict[str, Any]:
        return {
            "state": "disabled" if not self.enabled else "ready",
            "ready": True,
            "update_count": self.update_count,
            "rendered": self.figure is not None and self._figure_exists(),
        }

    def _render(self, packet: Packet) -> None:
        import matplotlib.pyplot as plt

        data = packet.data
        magnitude = np.asarray(data["magnitude_db"])
        range_axis = np.asarray(data["range_meters"], dtype=float)
        velocity_axis = np.asarray(data["velocity_meters_per_second"], dtype=float)
        if magnitude.ndim != 2 or magnitude.shape != (
            range_axis.size,
            velocity_axis.size,
        ):
            raise ValueError("range-Doppler packet arrays have incompatible shapes")
        if self.figure is None:
            visible = self.config.get("figure_visible", True)
            if _as_visible(visible):
                plt.ion()
            self.figure, self.axes = plt.subplots(figsize=(9, 6))
            # A Matplotlib Figure marked invisible is also omitted by some
            # non-interactive backends during savefig.  ``figure_visible``
            # therefore controls redraw/interactive updates below; the
            # figure itself stays renderable for both GUI and file output.
            self.figure.set_visible(True)
            self.axes.set_xlabel("Velocity (m/s)")
            self.axes.set_ylabel("Range (m)")
            self.axes.set_title("Dynamic Range-Doppler Spectrum")
            self.colorbar = None
            if _as_visible(visible):
                self.figure.show()
        # MATLAB stores positive velocity at the left edge.  Matplotlib is
        # clearer with an increasing x-axis, so reverse both axis and columns
        # together without changing the packet's numerical convention.
        extent = [
            float(velocity_axis[-1]),
            float(velocity_axis[0]),
            float(range_axis[0]),
            float(range_axis[-1]),
        ]
        display_map = magnitude[:, ::-1]
        limits = packet.quality.get("display_limits_db")
        if limits is None:
            limits = packet.quality.get("DisplayLimitsDb")
        if self.image is None:
            self.image = self.axes.imshow(
                display_map,
                origin="lower",
                aspect="auto",
                extent=extent,
                interpolation="nearest",
                cmap=self.config.get("colormap", "viridis"),
            )
            self.colorbar = self.figure.colorbar(self.image, ax=self.axes)
            self.colorbar.set_label("magnitude (dB)")
        else:
            self.image.set_data(display_map)
            self.image.set_extent(extent)
        if limits is not None:
            values = np.asarray(limits, dtype=float).reshape(-1)
            if values.size != 2 or not np.all(np.isfinite(values)):
                raise ValueError("display_limits_db must contain two finite values")
            self.image.set_clim(float(values[0]), float(values[1]))
        epoch = packet.meta.get("epoch", packet.meta.get("Epoch", "?"))
        sequence = packet.meta.get(
            "end_sequence", packet.meta.get("EndSequence", "?")
        )
        self.axes.set_title(
            f"Dynamic Range-Doppler Spectrum (epoch {epoch}, sequence {sequence})"
        )
        self.figure.tight_layout()
        if _as_visible(self.config.get("figure_visible", True)):
            self.figure.canvas.draw_idle()
            self.figure.canvas.flush_events()
            # ``flush_events`` updates already-pending GUI work.  A short
            # pause also gives the backend a chance to dispatch expose and
            # close events while a file-backed pipeline is processing quickly.
            refresh_pause = self.config.get("refresh_pause_seconds", 0.001)
            if refresh_pause is not None:
                plt.pause(float(refresh_pause))

    def _figure_exists(self) -> bool:
        if self.figure is None:
            return False
        import matplotlib.pyplot as plt

        return bool(plt.fignum_exists(self.figure.number))


class AsyncRangeDopplerViewer(Module):
    """Send only the newest map to a separate Matplotlib process.

    This test-side viewer keeps the acquisition and DSP pipeline out of the
    GUI event loop. A one-element queue deliberately drops stale maps when
    rendering falls behind; the display is a monitor, not a data consumer.
    """

    def __init__(self, config: Mapping[str, Any] | None = None) -> None:
        super().__init__("range_doppler_viewer", "range-doppler", "range-doppler")
        self.config = dict(config or {})
        self.enabled = bool(self.config.get("enabled", True))
        self.keep_open_on_end = bool(self.config.get("hold_on_end", False))
        self.accepted_count = 0
        self.dropped_count = 0
        self._context = mp.get_context("spawn")
        self._queue: Any = None
        self._process: mp.Process | None = None
        self._closed_event: Any = None
        self._ready_event: Any = None
        self._headless_event: Any = None
        self._shutdown_complete = False

    def initialize(self, runtime: Any) -> None:
        super().initialize(runtime)
        if not self.enabled:
            return
        self._queue = self._context.Queue(maxsize=1)
        self._closed_event = self._context.Event()
        self._ready_event = self._context.Event()
        self._headless_event = self._context.Event()
        self._process = self._context.Process(
            target=_viewer_process_main,
            args=(
                self._queue,
                self._closed_event,
                self._ready_event,
                self._headless_event,
                self.config,
            ),
            name="ltesen-range-doppler-viewer",
        )
        self._process.daemon = True
        self._process.start()

    def process(self, message: Message) -> Result:
        self.validate_input(message)
        if not self.enabled:
            return Result.forward(message)
        if self._closed_event is not None and self._closed_event.is_set():
            return Result.stop(message, "user-stopped")
        if message.has_packet:
            assert message.packet is not None
            if self._offer_latest(message.packet):
                self.accepted_count += 1
            else:
                self.dropped_count += 1
        return Result.forward(message)

    def finalize(self, reason: str) -> Result:
        if self.enabled and (
            reason == "failed"
            or not self.keep_open_on_end
            or (self._closed_event is not None and self._closed_event.is_set())
        ):
            self._shutdown()
        return Result.forward(Message.none())

    def close(self) -> None:
        self._shutdown()

    def wait_until_closed(self) -> None:
        """Keep a visible worker alive until its window is closed."""

        if not self.enabled or self._process is None:
            return
        if self._ready_event is not None:
            self._ready_event.wait(timeout=5.0)
        if self._headless_event is not None and self._headless_event.is_set():
            self._shutdown()
            return
        while self._process.is_alive():
            time.sleep(0.05)
        self._shutdown()

    def get_status(self) -> dict[str, Any]:
        alive = self._process is not None and self._process.is_alive()
        if not self.enabled:
            state = "disabled"
        elif alive:
            state = "running"
        else:
            state = "stopped"
        return {
            "state": state,
            "ready": self.enabled and self._process is not None,
            "update_count": self.accepted_count,
            "rendered": self.accepted_count > 0,
            "dropped_count": self.dropped_count,
            "process_alive": alive,
        }

    def _offer_latest(self, packet: Packet) -> bool:
        if self._queue is None:
            return False
        try:
            self._queue.put_nowait(packet)
            return True
        except queue.Full:
            try:
                self._queue.get_nowait()
            except queue.Empty:
                return False
            try:
                self._queue.put_nowait(packet)
                return True
            except queue.Full:
                return False

    def _shutdown(self) -> None:
        if self._shutdown_complete:
            return
        process = self._process
        if self._queue is not None and process is not None and process.is_alive():
            try:
                self._queue.put(None, timeout=0.5)
            except queue.Full:
                try:
                    self._queue.get_nowait()
                except queue.Empty:
                    pass
                try:
                    self._queue.put(None, timeout=0.5)
                except queue.Full:
                    pass
            process.join(timeout=5.0)
            if process.is_alive():
                process.terminate()
                process.join(timeout=2.0)
        if self._queue is not None:
            self._queue.close()
            self._queue.join_thread()
        self._shutdown_complete = True


def _viewer_process_main(
    packet_queue: Any,
    closed_event: Any,
    ready_event: Any,
    headless_event: Any,
    config: Mapping[str, Any],
) -> None:
    """Process entry point kept at module scope for Windows spawn."""

    try:
        import matplotlib.pyplot as plt

        worker_config = dict(config)
        backend = plt.get_backend().lower()
        headless = _is_headless_backend(backend)
        if headless:
            headless_event.set()
            worker_config["figure_visible"] = False
        viewer = RangeDopplerViewer(worker_config)
        ready_event.set()

        while True:
            try:
                packet = packet_queue.get(timeout=0.05)
            except queue.Empty:
                if viewer.figure is not None:
                    if not viewer._figure_exists():
                        break
                    if not headless:
                        plt.pause(0.01)
                continue
            if packet is None:
                break

            stop_after_render = False
            while True:
                try:
                    newer = packet_queue.get_nowait()
                except queue.Empty:
                    break
                if newer is None:
                    stop_after_render = True
                    break
                packet = newer

            viewer.process(Message.from_packet(packet))
            if stop_after_render:
                break
            if viewer.figure is not None and not viewer._figure_exists():
                break
    except Exception:
        # The parent still needs a deterministic way to stop its pipeline if
        # the GUI process fails during startup or rendering.
        traceback.print_exc()
    finally:
        ready_event.set()
        closed_event.set()


def save_range_doppler_plot(
    packet: Packet | Mapping[str, Any],
    path: str | Path,
    *,
    config: Mapping[str, Any] | None = None,
) -> Path:
    """Save one range-Doppler packet without constructing a pipeline."""

    normalized = packet if isinstance(packet, Packet) else Packet.from_mapping(packet)
    viewer = RangeDopplerViewer(
        {**dict(config or {}), "enabled": True, "figure_visible": False}
    )
    viewer._render(normalized)
    output = viewer.save(path)
    viewer.close()
    return output


def _as_visible(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip().lower() not in {"off", "false", "0", "hidden"}
    return bool(value)


def _is_headless_backend(backend: str) -> bool:
    """Return whether a Matplotlib backend cannot own a native window.

    Do not test for ``"agg" in backend`` here: GUI backends such as TkAgg and
    QtAgg deliberately contain the same suffix.
    """

    normalized = backend.lower().replace("module://", "")
    name = normalized.rsplit(".", 1)[-1]
    return name in {"agg", "cairo", "pdf", "pgf", "ps", "svg", "template"} or (
        "inline" in name
    )


__all__ = ["AsyncRangeDopplerViewer", "RangeDopplerViewer", "save_range_doppler_plot"]
