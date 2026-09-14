"""Optional Matplotlib viewer for range-Doppler packets."""

from __future__ import annotations

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


__all__ = ["RangeDopplerViewer", "save_range_doppler_plot"]
