# MATLAB LTE/5G Toolbox porting inventory

The MATLAB tree remains the reference implementation.  This inventory is
based on the calls currently present in `LTE_record_process`; it is a work
queue, not a claim that every MATLAB function has already been reimplemented.

## Receiver path

These functions are needed by `+ltesync/Acquirer.m` before a CSI packet can be
produced:

| MATLAB call | Role | Python plan |
| --- | --- | --- |
| `lteOFDMInfo` | FFT size, sample rate, CP lengths | Initial implementation: `ltesen.ltephy.lte_ofdm_info`; default table and explicit-NFFT CP validation checked against MATLAB |
| `lteCellSearch` | PSS/SSS cell identity and timing | Initial implementation: `ltesen.ltephy.cell_search`; PSS/SSS identity and FDD timing are covered by synthetic tests, but numerical parity on recordings is still pending |
| `lteFrequencyOffset` / `lteFrequencyCorrect` | CFO estimate and correction | Initial NumPy implementation: `ltesen.ltephy.lte_frequency_offset` and `lte_frequency_correct`; synthetic CP/tone tests pass |
| `lteDLFrameOffset` | Frame timing/correlation | Implemented as `ltesen.ltephy.lte_dl_frame_offset`; known-cell PSS/SSS timing, optional `CellRS`/`OmitEdgeRBs` CRS refinement, CRS-only fallback, FDD synthetic validation, and zero-based offset contract |
| project `ltesync.Acquirer` | Initial cell lock and MIB acquisition | Implemented as `ltesen.ltesync.Acquirer`; FDD Normal/Extended search, CFO, CRS/PBCH/MIB lock, and post-MIB frame timing are connected and validated on a real SigMF recording |
| `lteOFDMDemodulate` | Active-subcarrier OFDM grid | Initial implementation: `ltesen.ltephy.lte_ofdm_demodulate`; active-bin extraction, CP-window positioning, and explicit FFT-size support |
| `lteResourceGridSize` | Grid dimensions | Implemented: `ltesen.ltephy.lte_resource_grid_size`; downlink/uplink dimensions and CP variants are covered by unit tests |
| `lteDLChannelEstimate` | CRS-based channel/noise estimate | CRS LS pilots, UserDefined rectangular averaging, and srsRAN_4G-style frequency/time linear interpolation are implemented in `ltesen.ltephy.lte_dl_channel_estimate`; `none`/`nearest` modes and noise residual are covered by tests |
| `ltePBCHIndices` / `lteExtractResources` | PBCH resource extraction | Implemented as `ltesen.ltephy.lte_pbch_indices` and `lte_extract_resources`; center-6-RB PBCH layout, subframe gating, MATLAB index options, and 3-D/4-D all-planes extraction are covered by tests |
| `ltePBCHDecode` / `lteMIB` | BCH/MIB decoding and cell configuration | Initial end-to-end implementation: `lte_bch`, `lte_bch_decode`, `lte_pbch`, `lte_pbch_decode`, `lte_mib`, and `lte_pbch_prbs`; LTE CRC, tail-biting convolutional coding, rate matching, QPSK, 1/2/4-port diversity, and `nfmod4` search are covered by fixed-vector and MIB-recovery tests |

The initial acquisition boundary is now complete for FDD PBCH/MIB recovery,
and the first streaming receiver has been validated on one real recording.
The next robustness work is adding a production polyphase resampler, more
recordings, MATLAB EVM-specific interpolation variants, and TDD
special-subframe coverage.

## Tracking and CSI path

These calls are used after acquisition:

| MATLAB call | Role | Python status |
| --- | --- | --- |
| project `lteOFDMDemodulateFull` | Full FFT grid, including guard bins | Implemented as `ltesen.ltetracking.demodulate_full` |
| project `estimatePhaseSlopeFFT` | SFO/phase-slope estimate | Implemented as `estimate_phase_slope_fft` |
| project `ltetracking.CfoTracker` | Per-subframe CFO refinement | Implemented as `ltesen.ltetracking.CfoTracker`; coarse-lock correction plus cyclic-prefix residual update |
| project `ltetracking.CsiTracker` | Phase/SFO correction and static CSI filter | Implemented as `ltesen.ltetracking.CsiTracker`; phase-slope correction, stateful Butterworth-equivalent IIR update, dynamic CSI, timing shift, and warm-up status |
| project `ltesync.SyncSupervisor` | Synchronization health and reacquisition request | Implemented as `ltesen.ltesync.SyncSupervisor`; repeated low CP-correlation quality produces a receiver reacquisition event |
| project `ltetracking.fastDLCSIEstimate` | Direct CRS CSI extraction | Implemented as `ltesen.ltephy.lte_crs_csi` for Normal/Extended FDD with one or two transmit ports; `Receiver` precomputes CRS locations and all ten subframe reference-vector variants in `CrsReferenceCache` |
| project `ltetracking.Receiver` | Streaming raw IQ to CSI subframes | Implemented as `ltesen.ltetracking.Receiver`; emits `csi-subframe` packets, applies CSI tracking, monitors synchronization, and can trigger reacquisition |
| `lteCellRSIndices` / `lteCellRS` | CRS locations and symbols | Implemented as `ltesen.ltephy.lte_cell_rs_indices` and `lte_cell_rs`; port layouts, MATLAB index options, max-bandwidth sequence extraction, and MATLAB reference vectors are tested |
| `butter` / `filter` | Static CSI low-pass tracker | Implemented inside `ltesen.ltetracking.CsiTracker` with a dependency-free digital Butterworth design and stateful IIR filtering |
| MATLAB `resample` | Raw-rate to LTE-rate conversion | `ltesen.lteio.resample_waveform` uses a NumPy windowed-sinc anti-alias FIR for integer downsampling; non-integer ratios retain a deterministic linear fallback, while production polyphase filtering remains pending |
| `fft`, `ifft`, `fftshift` | Range-Doppler and phase processing | Covered by NumPy |
| project `lterd.RangeDopplerProcessor` | Windowed 2-D FFT and physical R-D axes | Implemented as `ltesen.lterd.RangeDopplerProcessor`; Hamming-windowed CRS/slow-time FFT, range/velocity axes, noise floor, and frame-window metadata |
| project `lterd.RangeDopplerViewer` | Range-Doppler visualization | Prototype kept outside the headless `ltesen` package under `tests/helpers`; `tests/plots/plot_range_doppler.py` saves a map from the bundled recording |

`comm.EVM` occurs only in the optional continuous-CSI diagnostic path.  It is
not a prerequisite for the core receiver rewrite.

## Waveform generator path

`LTE_waveform_generator.m` additionally calls `lteResourceGrid`,
`lteCellRSIndices`, `lteCellRS`, `ltePSS`, `ltePSSIndices`, `lteSSS`,
`lteSSSIndices`, `lteBCH`, `lteMIB`, `ltePBCH`, `ltePBCHIndices`, `lteDCI`,
`lteDCIEncode`, `ltePDCCH`, `ltePDCCHIndices`, `ltePDSCH`,
`ltePDSCHIndices`, and `lteOFDMModulate`.

This generator is useful for numerical fixtures, but it is deliberately later
than the recording reader and acquisition path.  It should not be recreated
with placeholder random symbols because that would make receiver tests look
valid while hiding LTE synchronization errors.

## MATLAB reference execution note

On Windows, MATLAB R2025b is installed at `C:\Program Files\MATLAB\R2025b` and
the normal user launch works. A launch from the restricted Codex sandbox can
instead fail with `File system inconsistency` before the MATLAB runtime starts.
The remedy is to run each reference command in the user's MATLAB session or
allow that specific `matlab -batch` command outside the sandbox. No MATLAB
project files need to be deleted or moved.
