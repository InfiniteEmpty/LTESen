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
- `ltesen.ltebuffer`: complete-CSI frame windows used by downstream processing
- `ltesen.lteio`: SigMF/legacy IQ readers, format selection, sample-rate metadata, and a NumPy anti-aliasing sample-rate converter for integer LTE downsampling
- `ltesen.ltesync`: raw/LTE sample-domain timebase, FDD PSS/SSS-to-PBCH acquisition lock, and synchronization-health supervision
- `ltesen.ltephy`: stateless LTE PHY primitives grouped similarly to srsRAN into `common`, `sync`, `ch_estimation`, `fec`, and `phch`, with OFDM kept as one Python module
- `ltesen.ltetracking`: stateful CFO refinement, CSI/SFO tracking, and the streaming frame-level CSI receiver source
- `ltesen.lterd`: headless windowed 2-D FFT range-Doppler processing
- `ltesen.config`: generic YAML loading and recursive overrides; module-specific validation stays with each consumer

The CSI packet array convention is `(subcarriers, time, receive_antennas,
transmit_antennas)`. A subframe has two time samples per resource block
column in the current data contract; a complete frame has twenty.

## Package boundaries

The LTE PHY layer is organized by protocol role rather than by one MATLAB
function per file:

```text
ltesen/ltephy/
  common/          numerology, Gold sequences, generic resource-grid helpers
  ofdm.py          reusable plans, full-bin and active-grid FFT
  sync/            PSS/SSS search, CFO primitives, frame timing
  ch_estimation/   CRS symbols/indices, channel estimation, direct CSI
  fec.py           CRC, convolutional coding, rate matching and decoding
  phch/            BCH/PBCH, MIB, scrambling, and PBCH resource indices
```

`ltephy` contains stateless signal-processing primitives. `ltesync` owns
acquisition and synchronization state, while `ltetracking` owns adaptive CFO
/CSI state and the frame-level receiver orchestration. `ltebuffer` contains
only downstream frame-window storage; the receiver itself emits complete
`csi-frame` packets.

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

To run the receiver, calculate one windowed R-D map from complete CSI frames,
and save it from the bundled recording:

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
