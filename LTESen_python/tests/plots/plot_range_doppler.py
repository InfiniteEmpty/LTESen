"""Run the current receiver chain and save one real-recording R-D map.

Usage from ``LTESen_python``::

    uv run --extra plot python tests/plots/plot_range_doppler.py
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
os.environ.setdefault("MPLCONFIGDIR", str(PROJECT_ROOT / ".mplconfig"))

import matplotlib

matplotlib.use("Agg")

from ltesen.config import load_config
from ltesen.ltebuffer import CsiFrameAssembler
from ltesen.lteio import open_recording
from ltesen.ltepipe import Pipeline
from ltesen.lterd import RangeDopplerProcessor
from ltesen.ltetracking import Receiver
from tests.helpers import RangeDopplerViewer


DEFAULT_ROOT = PROJECT_ROOT.parent / "experiment_data" / "rx_signal" / "LTE_20260825"
DEFAULT_RECORD = "LTE_20260825_000002"
DEFAULT_OUTPUT = PROJECT_ROOT / "tests" / "outputs" / "range_doppler" / (
    f"{DEFAULT_RECORD}_rd.png"
)


def plot_recording(
    root: Path,
    record_name: str,
    output: Path,
    *,
    iterations: int = 110,
) -> Path:
    config = load_config(
        overrides={
            "display": {"enabled": False},
            "execution": {"maximum_iterations": iterations, "verbose": False},
        }
    )
    recording = open_recording(root, record_name)
    receiver = Receiver(recording, config)
    assembler = CsiFrameAssembler()
    processor = RangeDopplerProcessor(config["range_doppler"])
    viewer = RangeDopplerViewer(
        {**config["display"], "enabled": True, "figure_visible": False}
    )
    pipeline = Pipeline(config["execution"])
    pipeline.register(receiver)
    pipeline.register(assembler)
    pipeline.register(processor)
    pipeline.register(viewer)
    pipeline.run()
    if viewer.update_count == 0:
        raise RuntimeError(
            "the recording ended before a complete range-Doppler window was available"
        )
    return viewer.save(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--record", default=DEFAULT_RECORD)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--iterations", type=int, default=110)
    args = parser.parse_args()
    output = plot_recording(
        args.root,
        args.record,
        args.output,
        iterations=args.iterations,
    )
    print(f"saved {output}")


if __name__ == "__main__":
    main()
