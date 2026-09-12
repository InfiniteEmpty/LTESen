# Modular LTE CRS sensing

`LTE_CRS_sense.m` is the interactive entry script for the shared processing
pipeline. Its `config.Cancellation.Method` selects passthrough processing or
frame-rate AR/Kalman interference cancellation without duplicating the sensing
flow in a second script.

Programmatic callers should construct an `IQDataFile`, edit a configuration
returned by `defaultLteSenseConfig`, and call `runLteCrsSense`.

```matlab
dataFile = lteio.openRecording(rootDirectory, recordName, 'auto');
config = defaultLteSenseConfig();
config.Cancellation.Method = 'ar-kalman';
config.Display.Enabled = false;
[summary, pipeline] = runLteCrsSense(dataFile, config);
```

## Module ownership

- `+lteio`: recording selection and all IQ recording reader implementations.
- `+ltesync`: initial acquisition, the absolute raw-sample timebase, and sync
  health supervision.
- `+ltetracking`: subframe reading, resampling, CFO correction, OFDM/CSI
  extraction, SFO correction, and static-CSI tracking.
- `+ltebuffer`: contiguous subframe-to-frame and frame-to-window assembly.
- `+ltecancel`: interchangeable frame-rate interference cancellers.
- `+lterd`: range-Doppler windowing and calculation.
- `+ltevisual`: shared figure ownership and result-specific viewers.

`LteSensePipeline` is deliberately explicit about boundaries that establish
shared packet contracts, such as subframe-to-frame assembly. Consumer-specific
history and multi-frame windows remain private to the algorithms that use them;
for example, the range-Doppler processor owns its `FrameWindow`. The pipeline is
not a generic list of untyped stages.

## Packet continuity

Every CSI packet carries an `Epoch`, a sequence number, LTE frame/subframe
metadata, and zero-based absolute positions in the raw recording. A true
reacquisition increments the epoch. Stateful downstream modules clear their
history when the epoch changes, and the frame assembler rejects partial or
non-consecutive frames.

Raw-file and LTE-domain sample quantities use distinct names. `ltesync.Timebase`
is the only owner of the file cursor and converts SFO timing feedback from LTE
samples to raw samples.

## Readiness

`Available` means that a call produced an output. `Status.Ready` describes
algorithm convergence. These are separate from `Epoch`, which describes data
continuity. During AR/Kalman warmup, the default `bypass` policy outputs the
uncancelled frame with `CancellationReady=false`. The policy can be changed to
`hold` or `drop`.

## Finalization and figures

`LteSensePipeline.run` always calls the idempotent `finalize` lifecycle method.
Computational modules return final artifacts without drawing them. The AR/Kalman
canceller therefore returns its final interference spectrum as data, and
`ltevisual.ArSpectrumViewer` renders it when display is enabled.

All viewers share one `ltevisual.FigureManager`, which is constructed by the
pipeline. The manager owns figure, tiled-layout, and axes handles, reuses them by
stable keys, remembers when a user closes a live window, and can disable all
graphics for tests. The default display maps the range-Doppler and AR spectrum
views to two axes in one `live-monitor` window. A view can be moved to another
window through `config.Display.Views` without changing its viewer.

Viewers never select the current figure or axes. They render only into the axes
provided by the manager and retain their image/line handles so live updates
replace plot data instead of recreating graphics objects. Plot-specific logic
therefore remains outside the manager.

## Synchronization status

The control path and epoch reset mechanism are implemented. CP-correlation
health monitoring is present but disabled by default until its thresholds are
validated on recordings with known gaps. Periodic known-PSS validation and a
synthetic insertion/deletion regression fixture are the next synchronization
milestone.

## Tests and deferred experiments

Active tests are under `tests/unit` and run through
`tests/run_all_unit_tests.m`. The previous continuous-CSI research branch is
preserved under `todo/continuous_csi`; it is intentionally excluded from the
active path and dependency guarantees.
