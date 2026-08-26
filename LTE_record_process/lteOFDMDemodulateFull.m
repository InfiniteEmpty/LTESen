function [fullGrid, info] = lteOFDMDemodulateFull(enb, waveform, cpFraction)
%LTEOFMDEMODULATEFULL  Full-band OFDM demodulation preserving ALL FFT bins
%   [fullGrid, info] = lteOFDMDemodulateFull(enb, waveform)
%   [fullGrid, info] = lteOFDMDemodulateFull(enb, waveform, cpFraction)
%
%   Performs OFDM demodulation like lteOFDMDemodulate, but returns the
%   complete Nfft-point FFT output including guard band subcarriers and
%   the DC subcarrier, allowing observation of sidelobe/leakage energy.
%
%   Inputs:
%     enb      - eNodeB configuration structure (same fields as used by
%                lteOFDMDemodulate, primarily: NDLRB, CyclicPrefix,
%                DuplexMode)
%     waveform - Time-domain baseband I/Q waveform, size [nSamples, nRxAnts]
%     cpFraction - (optional, default 1.0) fraction of the cyclic prefix
%                at which the FFT window starts. 1.0 = window starts at
%                the end of the CP (the zero-phase point), so no phase
%                correction is needed. Values < 1 start the window
%                earlier, improving robustness to timing error and
%                channel delay spread (lteOFDMDemodulate uses 0.55); a
%                per-bin phase correction then restores the zero-phase
%                reference so the output stays consistent with
%                cpFraction = 1.
%
%   Outputs:
%     fullGrid  - [Nfft, nSym, nRx] complex array — complete FFT spectrum
%                 for every OFDM symbol. The frequency axis is in MATLAB's
%                 native FFT order:
%                   row 1       → DC (0 Hz, unused in LTE)
%                   rows 2:Nfft/2 → positive frequencies (0 to +Fs/2)
%                   rows Nfft/2+1:Nfft → negative frequencies (-Fs/2 to 0-)
%                 Use fftshift(fullGrid, 1) to center DC for plotting.
%
%     info      - structure with fields:
%       .Nfft            - FFT size used
%       .SamplingRate    - baseband sampling rate (Hz)
%       .subcarrierSpacing - subcarrier spacing (Hz)
%       .activeIdx       - [N_act x 1] FFT row indices of active subcarriers
%       .dcIdx           - FFT row index of the DC subcarrier
%       .guardLowerIdx   - FFT row indices of lower-frequency guard band
%                          (more negative than the lowest active subcarrier)
%       .guardUpperIdx   - FFT row indices of upper-frequency guard band
%                          (more positive than the highest active subcarrier)
%       .freqAxis        - [Nfft x 1] frequency in Hz (FFT order, DC at 0)
%       .freqAxisShifted - [Nfft x 1] frequency in Hz (fftshift order)
%       .CpLengths       - CP length per symbol (matches ofdmInfo)
%       .cpFraction      - FFT window position used (fraction of CP)
%       .nSym            - number of demodulated OFDM symbols
%       .symMap          - [nSym x 1] symbol index within subframe (0-based)
%
%   Side-lobe analysis example:
%       [fullGrid, info] = lteOFDMDemodulateFull(enb, signal);
%       % Average magnitude spectrum across all symbols
%       magSpec = mean(abs(fullGrid), [2, 3]);
%       % fftshift for plotting
%       magSpecShifted = fftshift(magSpec);
%       fAxis = info.freqAxisShifted;
%       plot(fAxis/1e6, 20*log10(magSpecShifted));
%       xlabel('Frequency (MHz)'); ylabel('Magnitude (dB)');
%       hold on;
%       % Highlight guard bands
%       xline(fAxis(info.guardLowerIdx(1))/1e6, 'r--');
%       xline(fAxis(info.guardUpperIdx(end))/1e6, 'r--');
%
%   Differences vs. lteOFDMDemodulate:
%     - Returns ALL Nfft bins (not only the active subcarriers).
%     - Applies a 1/sqrt(Nfft) power-preserving scaling (the toolbox uses
%       an unscaled fft(), so its grids are sqrt(Nfft) larger).
%     - Default FFT window is at the CP end (cpFraction = 1); the toolbox
%       defaults to cpFraction = 0.55 plus a phase correction, which this
%       function reproduces when cpFraction < 1 is passed.

% -------------------------------------------------------------------------
% Parse inputs and get OFDM parameters
% -------------------------------------------------------------------------
ofdmInfo = lteOFDMInfo(enb);
nfft = double(ofdmInfo.Nfft);
cpLensFull = double(ofdmInfo.CyclicPrefixLengths);  % 1 × nSymPerSubframe (14 or 12)

if nargin < 3 || isempty(cpFraction)
    cpFraction = 1.0;   % window at CP end = zero-phase point (no correction)
end

nSamples = size(waveform, 1);
nRx = size(waveform, 2);
symbolsPerSubframe = length(cpLensFull);

% Determine number of full OFDM symbols available
symStartOffset = 1;
totalNeeded = 0;
nSym = 0;
while symStartOffset + totalNeeded <= nSamples
    cpLen = cpLensFull(mod(nSym, symbolsPerSubframe) + 1);
    symLen = nfft + cpLen;
    if symStartOffset + totalNeeded + symLen - 1 <= nSamples
        totalNeeded = totalNeeded + symLen;
        nSym = nSym + 1;
    else
        break;
    end
end

if nSym == 0
    fullGrid = [];
    info = struct();
    return;
end

% -------------------------------------------------------------------------
% CP removal and FFT demodulation
% -------------------------------------------------------------------------
fullGrid = zeros(nfft, nSym, nRx);
symMap = zeros(nSym, 1);

samplePos = symStartOffset;  % current read position in the waveform

for sym = 1:nSym
    symIdxInSF = mod(sym - 1, symbolsPerSubframe) + 1;
    cpLen = cpLensFull(symIdxInSF);
    symMap(sym) = symIdxInSF - 1;  % 0-based symbol index within subframe

    % Position the FFT window inside the symbol.
    % cpFraction = 1 → window starts at CP end (the zero-phase point).
    fftStart = floor(cpLen * cpFraction);
    delta = cpLen - fftStart;   % samples before the zero-phase point

    % Phase correction (per FFT bin q): a window placed delta samples
    % before the CP end rotates bin q by exp(-1j*2*pi*delta*q/Nfft).
    % Multiply by the conjugate ramp to undo the rotation and keep the
    % output aligned with the zero-phase convention. At delta = 0 the
    % correction is exactly 1, so the default behavior is unchanged.
    phaseCorr = exp(1j * 2 * pi * delta * (0:nfft-1).' / nfft);

    dataStart = samplePos + fftStart;
    dataEnd = dataStart + nfft - 1;

    for rx = 1:nRx
        symData = waveform(dataStart:dataEnd, rx);
        % FFT demodulation with power-preserving scaling.
        % (lteOFDMDemodulate uses an unscaled fft(), so its grids are
        % sqrt(Nfft) larger than the ones returned here.)
        fullGrid(:, sym, rx) = fft(symData, nfft) .* phaseCorr / sqrt(nfft);
    end

    % Advance past the whole symbol (CP + Nfft), regardless of window position
    samplePos = samplePos + cpLen + nfft;
end

% -------------------------------------------------------------------------
% Build frequency axis and subcarrier index maps
% -------------------------------------------------------------------------
N_carrier = double(enb.NDLRB) * 12;  % number of active subcarriers
samplingRate = double(ofdmInfo.SamplingRate);
deltaF = samplingRate / nfft;         % subcarrier spacing = 15 kHz

% Frequency axis in native FFT order (row 1 = DC = 0 Hz)
freqAxis = (0:nfft-1).' * deltaF;
% Wrap negative frequencies for correct display
freqAxis(freqAxis > samplingRate/2) = freqAxis(freqAxis > samplingRate/2) - samplingRate;

% fftshifted frequency axis (centered at DC)
if mod(nfft, 2) == 0
    freqAxisShifted = ((-nfft/2):(nfft/2-1)).' * deltaF;
else
    freqAxisShifted = ((-(nfft-1)/2):((nfft-1)/2)).' * deltaF;
end

% --- Subcarrier classification (all indices 1-based, FFT order) ---

% DC subcarrier is at FFT row 1 (0 Hz in native FFT order)
dcIdx = 1;

% In LTE, active subcarriers are numbered k relative to DC:
%   k = -floor(N_carrier/2) : -1,  +1 : +ceil(N_carrier/2)
%   (k = 0, the DC carrier, is unused)
%
% Mapping to FFT rows:
%   k < 0:  FFT row = nfft + 1 + k    (wraps to end of FFT output)
%   k > 0:  FFT row = k + 1           (just after DC)
%   k = 0:  FFT row = 1               (DC, unused)

halfAct = N_carrier / 2;  % half the active subcarriers (assumes even N_carrier)

% Active subcarriers: k = -halfAct, ..., -1, +1, ..., +halfAct
activeLower = (nfft + 1 - halfAct) : nfft;   % k = -halfAct : -1
activeUpper = 2 : (halfAct + 1);              % k = +1 : +halfAct
activeIdx = [activeLower, activeUpper].';

% Guard bands:
% Lower guard: k = -nfft/2 : -(halfAct+1)
guardLowerIdx = ((nfft/2 + 1) : (nfft - halfAct)).';

% Upper guard: k = +(halfAct+1) : +(nfft/2-1)
guardUpperIdx = (halfAct + 2 : nfft/2).';

% Verify total: DC(1) + active(N_carrier) + guardLower + guardUpper = nfft
% (should always hold for valid LTE configurations)
assert(length(activeIdx) == N_carrier, ...
    'Internal error: active subcarrier count mismatch.');
assert(length(guardLowerIdx) + length(guardUpperIdx) + N_carrier + 1 == nfft, ...
    'Internal error: total bin count mismatch.');

% -------------------------------------------------------------------------
% Pack output info structure
% -------------------------------------------------------------------------
info.Nfft = nfft;
info.SamplingRate = samplingRate;
info.subcarrierSpacing = deltaF;
info.activeIdx = activeIdx;
info.dcIdx = dcIdx;
info.guardLowerIdx = guardLowerIdx;
info.guardUpperIdx = guardUpperIdx;
info.freqAxis = freqAxis;
info.freqAxisShifted = freqAxisShifted;
info.CpLengths = cpLensFull;
info.cpFraction = cpFraction;
info.nSym = nSym;
info.symMap = symMap;

end
