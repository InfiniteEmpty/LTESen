# LTESen Python

This directory is the Python rewrite of `LTE_record_process`.
The MATLAB project remains the reference implementation and is intentionally
left unchanged.

The proposed multi-branch and carrier-aggregation execution architecture is
documented in the Chinese design note [`DAG_PIPELINE_DESIGN.md`](DAG_PIPELINE_DESIGN.md).

## Current phase

The current Python rewrite provides the reusable pipeline contract, recording
readers, and the first waveform-domain helpers:

- `ltesen.ltepipe`: messages, results, runtime context, modules, and pipeline
- `ltesen.ltebuffer`: ten-subframe CSI frame assembly and frame windows
- `ltesen.lteio`: SigMF/legacy IQ readers, format selection, sample-rate metadata, and a NumPy anti-aliasing sample-rate converter for integer LTE downsampling
- `ltesen.ltesync`: raw/LTE sample-domain timebase, FDD PSS/SSS-to-PBCH acquisition lock, and synchronization-health supervision
- `ltesen.ltephy`: LTE OFDM information, active-grid OFDM demodulation, PSS/SSS cell search, CFO helpers, known-cell frame timing, resource-grid sizing, CRS generation, PBCH indexing/resource extraction, BCH/PBCH coding and decoding, MIB bit-field parsing, PBCH scrambling, and the initial CRS channel estimator
- `ltesen.ltetracking`: full-bin OFDM demodulation, phase-slope estimation, CFO refinement, phase/SFO CSI tracking, and the streaming CSI receiver source
- `ltesen.lterd`: headless windowed 2-D FFT range-Doppler processing
- `ltesen.config`: YAML configuration loading and validation

The CSI packet array convention is `(subcarriers, time, receive_antennas,
transmit_antennas)`. A subframe has two time samples per resource block
column in the current data contract; a complete frame has twenty.

## uv environment

The project uses `uv` with its environment in this Python project directory.
From `LTESen_python`, initialize or synchronize it with:

```powershell
uv sync
```

Run commands inside the locked environment with `uv run`, for example:

```powershell
uv run python -m unittest discover -s tests -t . -v
```

The optional plotting dependency is kept out of the core environment. The
prototype viewer lives under `tests/helpers` so it can be replaced later by a
standalone `tools` or Qt GUI package. Install
it and generate a preview of the bundled SigMF recording with:

```powershell
uv sync --extra plot
uv run --extra plot python tests/plots/plot_signal_segment.py
```

Generated images are placed under `tests/outputs/` and are ignored by Git.

To run the receiver, assemble CSI frames, calculate one windowed R-D map, and
save it from the bundled recording:

```powershell
uv run --extra plot python tests/plots/plot_range_doppler.py
```

To keep the Matplotlib window open and update it whenever a new R-D window is
available, use:

```powershell
uv run --extra plot python tests/plots/view_range_doppler.py
```

The viewer keeps the final figure open after a file ends; close the window or
pass `--no-hold` to exit immediately. The current phase intentionally declares only NumPy and PyYAML. Dependencies
needed by later phases should be added with `uv add`, and the resulting lock
file should be committed together with the code change.

## MATLAB reference validation on Windows

When MATLAB is launched by the Codex execution environment, run the command
outside the restricted sandbox. A sandboxed launch can fail before MATLAB
starts with `Fatal Startup Error: File system inconsistency`, even though the
same installed R2025b executable works normally. This is an execution-user
filesystem isolation issue, not a project-path or MATLAB-installation issue.

For example, the reference command is:

```powershell
matlab -batch "help lteOFDMDemodulate"
```

After MATLAB help or numerical reference output is collected, keep the
corresponding Python test in `tests/unit/` so later toolbox ports remain
reproducible.

## Planned phases

1. Pipeline contract, YAML configuration, and pure buffering utilities.
2. Recording readers, raw/LTE timebase, and toolbox-independent tracking helpers.
3. Synchronization and acquisition refinement, including numerical validation
   of the PSS/SSS-to-MIB lock and the remaining MATLAB Toolbox boundaries.
4. OFDM demodulation, CRS extraction, CFO/SFO tracking, and CSI packets.
5. Range-Doppler processing and optional viewers.
6. Cancellation, MUSIC, and the higher-level sensing algorithms.

Each phase should add Python tests and preserve the MATLAB tree as a separate
reference until numerical behavior has been checked on recordings.
