"""Plot a short normalized IQ segment from an LTE recording.

The default input points at the SigMF recording already present in this
repository.  A different recording can be selected from the command line:

    uv run --extra plot python tests/plots/plot_signal_segment.py \
        --root ../experiment_data/rx_signal/LTE_20260825 \
        --record LTE_20260825_000002
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
os.environ.setdefault("MPLCONFIGDIR", str(PROJECT_ROOT / ".mplconfig"))

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from ltesen.lteio import open_recording


DEFAULT_ROOT = PROJECT_ROOT.parent / "experiment_data" / "rx_signal" / "LTE_20260825"
DEFAULT_RECORD = "LTE_20260825_000002"
DEFAULT_OUTPUT = PROJECT_ROOT / "tests" / "outputs" / "signal_preview" / (
    f"{DEFAULT_RECORD}_iq_segment.png"
)


def plot_signal_segment(
    root: Path,
    record_name: str,
    output: Path,
    *,
    start: int = 0,
    count: int = 4096,
) -> Path:
    """Read and plot ``count`` normalized complex samples."""

    if start < 0 or count <= 0:
        raise ValueError("start must be non-negative and count must be positive")
    recording = open_recording(root, record_name)
    sample_count = min(count, recording.sample_count - start)
    if sample_count <= 0:
        raise ValueError("the requested segment is outside the recording")
    samples = np.asarray(recording.read_at(start, sample_count, normalize=True))
    time_ms = (start + np.arange(samples.size)) / recording.sample_rate * 1000.0

    output.parent.mkdir(parents=True, exist_ok=True)
    figure, axes = plt.subplots(2, 1, figsize=(11, 6), sharex=True)
    figure.suptitle(
        f"{record_name}: normalized IQ segment "
        f"(samples {start:,}–{start + samples.size - 1:,})"
    )
    axes[0].plot(time_ms, samples.real, linewidth=0.7, label="I")
    axes[0].plot(time_ms, samples.imag, linewidth=0.7, label="Q")
    axes[0].set_ylabel("amplitude")
    axes[0].legend(loc="upper right")
    axes[0].grid(True, alpha=0.25)
    axes[1].plot(time_ms, np.abs(samples), linewidth=0.7, color="tab:green")
    axes[1].set_xlabel("time (ms)")
    axes[1].set_ylabel("magnitude")
    axes[1].grid(True, alpha=0.25)
    figure.tight_layout()
    figure.savefig(output, dpi=150)
    plt.close(figure)
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--record", default=DEFAULT_RECORD)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--count", type=int, default=4096)
    args = parser.parse_args()
    output = plot_signal_segment(
        args.root,
        args.record,
        args.output,
        start=args.start,
        count=args.count,
    )
    print(f"saved {output}")


if __name__ == "__main__":
    main()
