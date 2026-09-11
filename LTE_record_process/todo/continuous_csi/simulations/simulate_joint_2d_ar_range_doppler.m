%% Two-target demonstration of the recursive joint 2-D AR R-D spectrum
clear;
clc;
close all;
simulationDirectory = fileparts(mfilename('fullpath'));
continuousCsiDirectory = fileparts(simulationDirectory);
testScriptDirectory = fileparts(continuousCsiDirectory);
projectDirectory = fileparts(testScriptDirectory);
addpath(projectDirectory, fullfile(continuousCsiDirectory, 'core'));
rng(20260908);

%% Signal and target parameters
c = physconst('LightSpeed');
fc = 3.2e9;
subcarrierSpacing = 15e3;
crsSpacing = 6*subcarrierSpacing;
slowTimeSamplePeriod = 5e-4;

% Emulate LTE CRS group 1 on a 20 MHz carrier. The active grid omits DC;
% selecting every sixth active carrier therefore also preserves the real
% frequency gap at DC instead of making the row indices artificially uniform.
activeBins = [-600:-1 1:600];
crsBins = activeBins(4:6:end).';
carrierOffsetsHz = crsBins*subcarrierSpacing;
carrierHz = fc+carrierOffsetsHz;

sampleCount = 2000;
slowTime = (0:sampleCount-1)*slowTimeSamplePeriod;
initialRange = [80 230];                 % m, at the first sample
radialVelocity = [4 -6];                 % m/s
targetAmplitude = [1 0.70].*exp(1i*[0.25 -1.10]);
inputSnrDb = -8;                         % average per-CRS-sample SNR
saveResultImage = true;

%% Generate physically consistent multi-carrier CSI
cleanCSI = complex(zeros(numel(carrierHz), sampleCount));
for target = 1:numel(initialRange)
    targetRange = initialRange(target)+radialVelocity(target)*slowTime;
    % Round-trip phase includes the absolute carrier frequency. Consequently,
    % each target Doppler is proportional to carrier frequency, as in real CSI.
    cleanCSI = cleanCSI+targetAmplitude(target)*exp( ...
        -1i*4*pi/c*(carrierHz*targetRange));
end
signalPower = mean(abs(cleanCSI).^2, 'all');
noisePower = signalPower/10^(inputSnrDb/10);
noise = sqrt(noisePower/2)*(randn(size(cleanCSI))+1i*randn(size(cleanCSI)));
measuredCSI = cleanCSI+noise;

%% Shared anchored interpolation and recursive joint correlation
windowLength = 200;
rangeOrder = 24;
dopplerOrder = 24;
forgettingFactor = 0.998;
kernelTolerance = 1e-8;
guardSamples = 12;

% One interpolator owns the raw history and the current anchor. It recursively
% maintains only the first dopplerOrder+1 outputs needed on every update; the
% complete window is generated from the same state for the final 2-D FFT.
resampler = AnchoredSincResampler(carrierHz, fc, windowLength, ...
    kernelTolerance, guardSamples, dopplerOrder+1);
correlationState = Recursive2DAutocorrelation(carrierHz, crsSpacing, ...
    rangeOrder, dopplerOrder, forgettingFactor);

for sample = 1:sampleCount
    resampler.push(measuredCSI(:, sample));
    if resampler.SampleCount >= resampler.HistoryLength
        alignedLags = resampler.snapshot(dopplerOrder+1);
        % This single call forms every (range lag, Doppler lag) product before
        % averaging or exponential accumulation; neither dimension is collapsed.
        correlationState.push(alignedLags);
    end
end
assert(correlationState.SampleCount > 0, ...
    'The simulation is too short to fill the interpolation history.');

%% Joint 2-D AR, joint 2-D MUSIC, and current-window 2-D FFT
rangePoints = 2048;
dopplerPoints = 800;
diagonalLoading = 1e-3;
[arPower, arCoefficients, predictionError, usedLoading, fitRcond] = ...
    jointArRangeDopplerSpectrum(correlationState.Correlation, ...
    rangeOrder, dopplerOrder, rangePoints, dopplerPoints, diagonalLoading);
musicSignalCount = 2; % known truth for this demonstration
[musicPower, musicEigenvalues, musicLoading, musicRcond] = ...
    jointMusicRangeDopplerSpectrum(correlationState.Correlation, ...
    rangeOrder, dopplerOrder, rangePoints, dopplerPoints, ...
    musicSignalCount, diagonalLoading);

alignedCSI = resampler.snapshot();
[fftPower, fftRangeAxis, fftDopplerHz] = anchoredRangeDopplerFFT( ...
    alignedCSI, carrierOffsetsHz, subcarrierSpacing, rangePoints, ...
    dopplerPoints, slowTimeSamplePeriod);

% Convert the 2-D AR spatial-frequency rows to the same signed range order
% used by the range IFFT. The +/-pi endpoint is handled as one periodic bin.
rangeBins = -floor(rangePoints/2):ceil(rangePoints/2)-1;
arRangeAxis = rangeBins*c/(2*crsSpacing*rangePoints);
arSpatialBins = mod(-rangeBins+floor(rangePoints/2), rangePoints) ...
    - floor(rangePoints/2);
[allBinsFound, arRangeOrder] = ismember(arSpatialBins, rangeBins);
assert(all(allBinsFound), 'Unable to construct the 2-D AR range axis.');

[velocityAxis, velocityOrder] = sort(-fftDopplerHz*c/(2*fc));
rangeHalfSpan = c/(4*crsSpacing);
arRangeMask = arRangeAxis >= -rangeHalfSpan & arRangeAxis < rangeHalfSpan;
fftRangeMask = fftRangeAxis >= -rangeHalfSpan & fftRangeAxis < rangeHalfSpan;

arDisplayPower = arPower(arRangeOrder(arRangeMask), velocityOrder);
musicDisplayPower = musicPower(arRangeOrder(arRangeMask), velocityOrder);
fftDisplayPower = fftPower(fftRangeMask, velocityOrder);
arDb = normalizedDb(arDisplayPower);
musicDb = normalizedDb(musicDisplayPower);
fftDb = normalizedDb(fftDisplayPower);
finalRange = initialRange+radialVelocity*slowTime(end);

%% Display the two spectra and target truth
simulationFigure = figure('Name', 'Two-target joint 2-D spectral comparison', ...
    'Color', 'w');
layout = tiledlayout(simulationFigure, 1, 3, 'TileSpacing', 'compact', ...
    'Padding', 'compact');

arAxes = nexttile(layout);
imagesc(arAxes, velocityAxis, arRangeAxis(arRangeMask), arDb);
configureAxes(arAxes, radialVelocity, finalRange, ...
    sprintf('Recursive joint 2-D AR (%d updates)', correlationState.SampleCount));

musicAxes = nexttile(layout);
imagesc(musicAxes, velocityAxis, arRangeAxis(arRangeMask), musicDb);
configureAxes(musicAxes, radialVelocity, finalRange, ...
    sprintf('Joint 2-D MUSIC (D=%d)', musicSignalCount));

fftAxes = nexttile(layout);
imagesc(fftAxes, velocityAxis, fftRangeAxis(fftRangeMask), fftDb);
configureAxes(fftAxes, radialVelocity, finalRange, ...
    sprintf('Current %d-sample 2D-FFT', windowLength));

musicEigenGap = musicEigenvalues(musicSignalCount) / ...
    max(musicEigenvalues(musicSignalCount+1), eps);
layoutTitle = title(layout, sprintf(['Two physical moving targets, input SNR %.1f dB; ' ...
    'MUSIC eigengap %.2g'], inputSnrDb, musicEigenGap));
layoutTitle.Color = 'k';

fprintf('Joint correlation size: %d x %d\n', size(correlationState.Correlation));
fprintf('Recursive updates: %d, effective weight: %.3f\n', ...
    correlationState.SampleCount, correlationState.Weight);
fprintf('2-D AR parameters: %d, prediction error: %.4g\n', ...
    numel(arCoefficients)-1, predictionError);
fprintf(['MUSIC signal count: %d, loading: %.3g, covariance rcond: %.3g, ' ...
    'eigengap: %.3g\n'], musicSignalCount, musicLoading, musicRcond, musicEigenGap);
for target = 1:numel(finalRange)
    [arEstimatedRange, arEstimatedVelocity] = localPeakEstimate( ...
        arDisplayPower, arRangeAxis(arRangeMask), velocityAxis, ...
        finalRange(target), radialVelocity(target));
    [musicEstimatedRange, musicEstimatedVelocity] = localPeakEstimate( ...
        musicDisplayPower, arRangeAxis(arRangeMask), velocityAxis, ...
        finalRange(target), radialVelocity(target));
    fprintf(['Target %d truth: range %.2f m, velocity %.2f m/s; ' ...
        'AR peak: %.2f m, %.2f m/s; MUSIC peak: %.2f m, %.2f m/s\n'], ...
        target, finalRange(target), radialVelocity(target), ...
        arEstimatedRange, arEstimatedVelocity, ...
        musicEstimatedRange, musicEstimatedVelocity);
end
if saveResultImage
    outputDirectory = fullfile(testScriptDirectory, 'outputs', 'continuous_csi');
    if ~isfolder(outputDirectory), mkdir(outputDirectory); end
    exportgraphics(simulationFigure, fullfile(outputDirectory, ...
        'two_target_joint_2d_music_comparison.png'), 'Resolution', 140);
end

function db = normalizedDb(power)
    peak = max(power, [], 'all');
    db = 10*log10(max(power/max(peak, realmin), realmin));
end

function configureAxes(axesHandle, targetVelocity, targetRange, plotTitle)
    set(axesHandle, 'YDir', 'normal');
    colormap(axesHandle, 'turbo');
    colorbar(axesHandle);
    clim(axesHandle, [-45 0]);
    xlabel(axesHandle, 'Equivalent radial velocity (m/s)');
    ylabel(axesHandle, 'Equivalent range (m)');
    axesTitle = title(axesHandle, plotTitle);
    axesTitle.Color = 'k';
    set(axesHandle, 'XColor', 'k', 'YColor', 'k');
    velocityMargin = max(5, 0.25*(max(targetVelocity)-min(targetVelocity)));
    rangeMargin = max(40, 0.15*(max(targetRange)-min(targetRange)));
    xlim(axesHandle, [min(targetVelocity)-velocityMargin, ...
        max(targetVelocity)+velocityMargin]);
    ylim(axesHandle, [min(targetRange)-rangeMargin, ...
        max(targetRange)+rangeMargin]);
    grid(axesHandle, 'on');
    hold(axesHandle, 'on');
    plot(axesHandle, targetVelocity, targetRange, 'wo', ...
        'MarkerSize', 9, 'LineWidth', 1.6);
    hold(axesHandle, 'off');
end

function [rangeEstimate, velocityEstimate] = localPeakEstimate( ...
        power, rangeAxis, velocityAxis, expectedRange, expectedVelocity)
    rangeCandidates = find(abs(rangeAxis-expectedRange) <= 12);
    velocityCandidates = find(abs(velocityAxis-expectedVelocity) <= 3);
    localPower = power(rangeCandidates, velocityCandidates);
    [~, linearIndex] = max(localPower, [], 'all', 'linear');
    [rangeIndex, velocityIndex] = ind2sub(size(localPower), linearIndex);
    rangeEstimate = rangeAxis(rangeCandidates(rangeIndex));
    velocityEstimate = velocityAxis(velocityCandidates(velocityIndex));
end
