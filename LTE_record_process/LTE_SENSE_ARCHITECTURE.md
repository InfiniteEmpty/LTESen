# Modular LTE CRS sensing

`LTE_CRS_sense.m` is the interactive entry script for the shared processing
pipeline. Its `config.Cancellation.Method` selects passthrough processing or
frame-rate AR/Kalman interference cancellation without duplicating the sensing
flow in a second script.

`LTE_CRS_sense.m` is also the composition root: it constructs the selected
modules, registers them in data-flow order, and runs the pipeline. Programmatic
callers can use the same registration pattern.

```matlab
dataFile = lteio.openRecording(rootDirectory, recordName, 'auto');
config = defaultLteSenseConfig();
config.Cancellation.Method = 'ar-kalman';
config.Display.Enabled = false;

rangeDopplerAxes = struct('Main', gobjects(0));
arAxes = struct('Spectrum', gobjects(0));
% When display is enabled, create the shared figure, tiled layout, and axes.
pipeline = ltepipe.Pipeline(config.Execution);
pipeline.register(ltetracking.Receiver(dataFile, config));
pipeline.register(ltebuffer.CsiFrameAssembler());
pipeline.register(ltecancel.ArKalmanCanceller(config.Cancellation));
pipeline.register(ltecancel.ArSpectrumViewer( ...
    config.Display, arAxes));
pipeline.register(lterd.Processor(config.RangeDoppler));
pipeline.register(lterd.Viewer( ...
    config.Display, rangeDopplerAxes));
summary = pipeline.run();
```

## Module ownership

- `+lteio`: recording selection and all IQ recording reader implementations.
- `+ltepipe`: the common module, message, result, and runtime protocols.
- `+ltesync`: initial acquisition, the absolute raw-sample timebase, and sync
  health supervision.
- `+ltetracking`: subframe reading, resampling, CFO correction, OFDM/CSI
  extraction, SFO correction, and static-CSI tracking.
- `+ltebuffer`: contiguous subframe-to-frame and frame-to-window assembly.
- `+ltecancel`: interchangeable frame-rate cancellers and their AR viewer.
- `+lterd`: range-Doppler calculation and its packet viewer.
- `+ltevisual`: common viewer lifecycle and pass-through behavior.

`ltepipe.Pipeline` is a general connector rather than an LTE algorithm
coordinator. It lives beside the message and module protocols because it has no
LTE-specific behavior. It stores an ordered cell array of `ltepipe.Module`
instances and calls the same
`initialize`, `process`, `reset`, `finalize`, and `getStatus` interface for every
module. It contains no receiver, canceller, range-Doppler, or viewer branches.
Module names and declared packet types are checked during registration.

The current linear flow is:

```text
Receiver -> CsiFrameAssembler -> Canceller -> ArSpectrumViewer
         -> RangeDoppler Processor -> RangeDoppler Viewer
```

Viewers are pass-through modules. Consumer-specific history and multi-frame
windows remain private to the algorithms that use them; for example, the
range-Doppler processor owns its `FrameWindow`.

## Messages and control flow

Modules exchange a common message containing an optional typed packet and a
list of artifacts. `HasPacket=false` means that a buffering stage has no primary
output yet; it does not stop message traversal, because artifacts and UI control
may still need to reach later modules.

Every `process` call returns the same result structure. Its directive is one of
`continue`, `reset-downstream`, or `stop`. End-of-file is a normal `stop`; a
reacquisition is a `reset-downstream` carrying the new epoch and reason. The
pipeline interprets these generic directives without inspecting module-specific
fields. `Status.Ready` remains module state and is independent of packet
availability or control flow.

Initialization uses a shared `ltepipe.Runtime`. The receiver publishes the LTE
context after acquisition and later computational modules consume it. A future
downstream sync module can send a named command to the receiver without holding
a direct reference to it.

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

`Message.HasPacket` means that a call produced a primary output.
`Status.Ready` describes algorithm convergence. These are separate from
`Epoch`, which describes data continuity. During AR/Kalman warmup, the default
`bypass` policy outputs the uncancelled frame with `CancellationReady=false`.
The policy can be changed to `hold` or `drop`.

## Finalization and figures

`ltepipe.Pipeline.run` always calls the idempotent `finalize` lifecycle method.
Computational modules return final artifacts without drawing them. The pipeline
routes each final message through the remaining modules, so the AR/Kalman
canceller's spectrum reaches `ltecancel.ArSpectrumViewer` without a special
Pipeline branch.

`LTE_CRS_sense.m` explicitly creates the shared figure, tiled layout, and axes,
then injects each viewer's axes as a named struct. A viewer that owns several
plots can receive, for example, `struct('Spectrum', spectrumAxes, 'PoleMap',
poleAxes)`. This fixed layout is part of the composition root rather than a
runtime service.

`ltevisual.ViewerBase` owns the common axes/figure lifecycle, message
pass-through, update count, status, and user-close detection. Domain viewers
render only into their injected axes and retain their image/line handles so
live updates replace plot data instead of recreating graphics objects.

## Synchronization status

The control path and epoch reset mechanism are implemented. CP-correlation
health monitoring is enabled in the current default configuration. Its
thresholds still need validation on recordings with known gaps. Periodic
known-PSS validation and a synthetic insertion/deletion regression fixture are
the next synchronization milestone.

## Tests and deferred experiments

Active tests are under `tests/unit` and run through
`tests/run_all_unit_tests.m`. Manually generated experiment results belong in
the ignored `tests/outputs` directory; fixed inputs required by automated tests
belong in `tests/fixtures`. The previous continuous-CSI research branch is
preserved under `todo/continuous_csi`; it is intentionally excluded from the
active path and dependency guarantees.
