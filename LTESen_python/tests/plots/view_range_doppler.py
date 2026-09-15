"""Display a live range-Doppler window while the receiver processes a file.

Close the Matplotlib window to stop the pipeline.  Usage from
``LTESen_python``::

    uv --cache-dir .uv-cache run --extra plot python tests/plots/view_range_doppler.py
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
os.environ.setdefault("MPLCONFIGDIR", str(PROJECT_ROOT / ".mplconfig"))

from ltesen.config import load_config
from ltesen.lteio import open_recording
from ltesen.ltepipe import Pipeline
from ltesen.lterd import RangeDopplerProcessor
from ltesen.ltetracking import Receiver
from tests.helpers import AsyncRangeDopplerViewer, RangeDopplerViewer


DEFAULT_ROOT = PROJECT_ROOT.parent / "experiment_data" / "rx_signal" / "LTE_20260825"
DEFAULT_RECORD = "LTE_20260825_000001"


def run_viewer(
    root: Path,
    record_name: str,
    *,
    iterations: int | None = None,
    hold_on_end: bool = True,
    display_enabled: bool = True,
    async_display: bool = True,
) -> dict[str, object]:
    config = load_config(
        overrides={
            "display": {
                "enabled": display_enabled,
                "figure_visible": display_enabled,
                "hold_on_end": hold_on_end,
            },
            "execution": {"maximum_iterations": iterations, "verbose": True},
        }
    )
    recording = open_recording(root, record_name)
    pipeline = Pipeline(config["execution"])
    pipeline.register(Receiver(recording, config))
    pipeline.register(RangeDopplerProcessor(config["range_doppler"]))
    viewer_type = (
        AsyncRangeDopplerViewer
        if display_enabled and async_display
        else RangeDopplerViewer
    )
    viewer = viewer_type(config["display"])
    pipeline.register(viewer)
    summary = pipeline.run()
    if hold_on_end:
        _hold_window(viewer)
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--record", default=DEFAULT_RECORD)
    parser.add_argument("--iterations", type=int, default=None)
    parser.add_argument(
        "--no-hold",
        action="store_true",
        help="exit when the recording ends instead of keeping the final window open",
    )
    parser.add_argument(
        "--no-display",
        action="store_true",
        help="run the receiver without constructing the Matplotlib viewer",
    )
    parser.add_argument(
        "--sync-display",
        action="store_true",
        help="keep Matplotlib in the pipeline process for comparison",
    )
    args = parser.parse_args()
    summary = run_viewer(
        args.root,
        args.record,
        iterations=args.iterations,
        hold_on_end=not args.no_hold,
        display_enabled=not args.no_display,
        async_display=not args.sync_display,
    )
    print(summary["termination_reason"])


def _hold_window(viewer: RangeDopplerViewer | AsyncRangeDopplerViewer) -> None:
    """Keep an interactive final figure open, but never block headless runs."""

    if isinstance(viewer, AsyncRangeDopplerViewer):
        viewer.wait_until_closed()
        return

    if not viewer.get_status()["rendered"]:
        return
    import matplotlib.pyplot as plt

    backend = plt.get_backend().lower()
    if "agg" in backend or "pdf" in backend or "svg" in backend:
        return
    plt.ioff()
    plt.show(block=True)


if __name__ == "__main__":
    main()
