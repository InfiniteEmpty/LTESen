# Modular LTE CRS sensing

The two entry scripts now share one processing pipeline:

- `LTE_CRS_sense.m`: CSI and range-Doppler processing without interference
  cancellation.
- `LTE_CRS_sense_KF_denoise.m`: the same receiver and buffering path with
  frame-rate AR/Kalman cancellation enabled.

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
- `+lterd`: range-Doppler calculation and display.

`LteSensePipeline` is deliberately explicit about the subframe, frame, and
multi-frame rate boundaries. It is not a generic list of untyped stages.

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
