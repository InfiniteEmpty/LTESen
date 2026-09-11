function tests = test_Recursive2DAutocorrelation
    tests = functiontests(localfunctions);
end

function setupOnce(testCase)
    testPath = fileparts(mfilename('fullpath'));
    continuousCsiPath = fileparts(testPath);
    projectPath = fileparts(fileparts(continuousCsiPath));
    corePath = fullfile(continuousCsiPath, 'core');
    testCase.applyFixture(matlab.unittest.fixtures.PathFixture(projectPath));
    testCase.applyFixture(matlab.unittest.fixtures.PathFixture(corePath));
end

function testJointIncrementUsesActualFrequencyPairs(testCase)
    rng(71);
    spacing = 90e3;
    % Missing zero carrier: a row-neighbour implementation would incorrectly
    % pair -spacing with +spacing at spatial lag one.
    bins = [-3 -2 -1 1 2 3].';
    state = Recursive2DAutocorrelation(3.2e9+bins*spacing, ...
        spacing, 2, 3, 0.9);
    data = randn(6, 4)+1i*randn(6, 4);
    state.push(data);
    expected = directJointIncrement(data, bins, 2, 3);
    verifyEqual(testCase, state.LastIncrement, expected, 'AbsTol', 1e-12);
    verifyEqual(testCase, state.Correlation, expected, 'AbsTol', 1e-12);
    verifyEqual(testCase, state.PairCount, [3; 4; 6; 4; 3]);
end

function testClosedFormExponentialAccumulation(testCase)
    rng(72);
    spacing = 90e3;
    bins = (-5:5).';
    Pr = 3;
    Pt = 5;
    lambda = 0.997;
    state = Recursive2DAutocorrelation(3.2e9+bins*spacing, ...
        spacing, Pr, Pt, lambda);
    increments = complex(zeros(2*Pr+1, Pt+1, 80));
    for n = 1:size(increments, 3)
        data = randn(numel(bins), Pt+1)+1i*randn(numel(bins), Pt+1);
        state.push(data);
        increments(:, :, n) = directJointIncrement(data, bins, Pr, Pt);
    end
    weights = reshape(lambda.^((size(increments, 3)-1):-1:0), 1, 1, []);
    expectedNumerator = sum(increments.*weights, 3);
    expectedWeight = sum(weights);
    verifyEqual(testCase, state.Numerator, expectedNumerator, 'AbsTol', 1e-10);
    verifyEqual(testCase, state.Weight, expectedWeight, 'AbsTol', 1e-12);
    verifyEqual(testCase, state.Correlation, ...
        expectedNumerator/expectedWeight, 'AbsTol', 1e-12);
    verifyEqual(testCase, state.SampleCount, size(increments, 3));
end

function testPlaneWaveRetainsJointPhase(testCase)
    spacing = 90e3;
    bins = (-8:8).';
    Pr = 4;
    Pt = 8;
    omegaRange = -0.63;
    omegaDoppler = 0.41;
    [carrierIndex, newestFirstTime] = ndgrid(bins, 0:Pt);
    data = exp(1i*(omegaRange*carrierIndex-omegaDoppler*newestFirstTime));
    state = Recursive2DAutocorrelation(3.2e9+bins*spacing, ...
        spacing, Pr, Pt, 1);
    state.push(data);
    [df, dt] = ndgrid(-Pr:Pr, 0:Pt);
    expected = exp(1i*(omegaRange*df+omegaDoppler*dt));
    verifyEqual(testCase, state.Correlation, expected, 'AbsTol', 1e-12);
    % This mixed phase cannot be recovered after independently reducing
    % either dimension to a one-dimensional power statistic.
    verifyEqual(testCase, angle(state.Correlation(Pr+3, 4)), ...
        angle(expected(Pr+3, 4)), 'AbsTol', 1e-12);
end

function testTwoTargetJointArSpectrum(testCase)
    Pr = 5;
    Pt = 10;
    points = 256;
    omegaRange = [-0.80 0.55];
    omegaDoppler = [0.90 -0.45];
    amplitude = [1 0.7];
    [df, dt] = ndgrid(-Pr:Pr, 0:Pt);
    correlation = complex(zeros(size(df)));
    for target = 1:2
        correlation = correlation+amplitude(target)^2*exp(1i*( ...
            omegaRange(target)*df+omegaDoppler(target)*dt));
    end
    correlation(Pr+1, 1) = correlation(Pr+1, 1)+0.1; % white noise
    before = correlation;
    [power, coefficients, predictionError, loading, fitRcond] = ...
        jointArRangeDopplerSpectrum(correlation, Pr, Pt, ...
        points, points, 1e-3);
    omega = 2*pi*(-points/2:points/2-1)/points;
    for target = 1:2
        [~, rangeBin] = min(abs(omega-omegaRange(target)));
        [~, dopplerBin] = min(abs(omega-omegaDoppler(target)));
        percentile = mean(power(:) <= power(rangeBin, dopplerBin));
        verifyGreaterThan(testCase, percentile, 0.999);
    end
    verifyEqual(testCase, coefficients(1, 1), 1);
    verifyGreaterThan(testCase, predictionError, 0);
    verifyGreaterThanOrEqual(testCase, loading, 1e-3);
    verifyGreaterThan(testCase, fitRcond, 0);
    verifyTrue(testCase, all(isfinite(power), 'all'));
    verifyEqual(testCase, correlation, before); % fitting is a read-only operation
end

function testTwoTargetMusicSpectrumHasPointPeaks(testCase)
    Pr = 5;
    Pt = 10;
    points = 256;
    omegaRange = [-0.80 0.55];
    omegaDoppler = [0.90 -0.45];
    amplitude = [1 0.7];
    [df, dt] = ndgrid(-Pr:Pr, 0:Pt);
    correlation = complex(zeros(size(df)));
    for target = 1:2
        correlation = correlation+amplitude(target)^2*exp(1i*( ...
            omegaRange(target)*df+omegaDoppler(target)*dt));
    end
    correlation(Pr+1, 1) = correlation(Pr+1, 1)+0.05;
    before = correlation;
    [power, eigenvalues, loading, covarianceRcond] = ...
        jointMusicRangeDopplerSpectrum(correlation, Pr, Pt, ...
        points, points, 2, 1e-6);
    omega = 2*pi*(-points/2:points/2-1)/points;
    for target = 1:2
        rangeCandidates = find(abs(omega-omegaRange(target)) < 0.15);
        dopplerCandidates = find(abs(omega-omegaDoppler(target)) < 0.15);
        [~, localIndex] = max(power(rangeCandidates, dopplerCandidates), ...
            [], 'all', 'linear');
        [rangeIndex, dopplerIndex] = ind2sub( ...
            [numel(rangeCandidates), numel(dopplerCandidates)], localIndex);
        verifyLessThan(testCase, abs(omega(rangeCandidates(rangeIndex)) ...
            - omegaRange(target)), 2*pi/points*1.1);
        verifyLessThan(testCase, abs(omega(dopplerCandidates(dopplerIndex)) ...
            - omegaDoppler(target)), 2*pi/points*1.1);
    end
    verifyGreaterThan(testCase, eigenvalues(2)/eigenvalues(3), 100);
    verifyGreaterThanOrEqual(testCase, loading, 1e-6);
    verifyGreaterThan(testCase, covarianceRcond, 0);
    verifyTrue(testCase, all(isfinite(power), 'all'));
    verifyEqual(testCase, correlation, before);
end

function testSharedInterpolatorFeedsBothConsumers(testCase)
    rng(73);
    fc = 3.2e9;
    spacing = 90e3;
    bins = (-4:4).';
    resampler = AnchoredSincResampler(fc+bins*spacing, fc, 40, 1e-10, 8, 6);
    state = Recursive2DAutocorrelation(fc+bins*spacing, spacing, 2, 5, 0.998);
    data = randn(numel(bins), 100)+1i*randn(numel(bins), 100);
    expectedUpdates = 0;
    for n = 1:size(data, 2)
        resampler.push(data(:, n));
        if resampler.SampleCount >= resampler.HistoryLength
            state.push(resampler.snapshot(state.TemporalOrder+1));
            expectedUpdates = expectedUpdates+1;
        end
    end
    fullSnapshot = resampler.snapshot();
    verifyEqual(testCase, fullSnapshot(:, 1:state.TemporalOrder+1), ...
        resampler.snapshot(state.TemporalOrder+1), 'AbsTol', 1e-9);
    verifyEqual(testCase, state.SampleCount, expectedUpdates);
end

function testZeroPowerAndInputValidation(testCase)
    power = jointArRangeDopplerSpectrum(zeros(5, 4), 2, 3, 32, 64, 1e-3);
    verifyEqual(testCase, power, zeros(32, 64));
    musicPower = jointMusicRangeDopplerSpectrum( ...
        zeros(5, 4), 2, 3, 32, 64, 2, 1e-3);
    verifyEqual(testCase, musicPower, zeros(32, 64));
    state = Recursive2DAutocorrelation(3.2e9+(-2:2)'*90e3, 90e3, 2, 3, 1);
    verifyError(testCase, @() state.push(zeros(4, 4)), ...
        'Recursive2DAutocorrelation:CarrierCount');
    verifyError(testCase, @() state.push(zeros(5, 3)), ...
        'Recursive2DAutocorrelation:TemporalLags');
    verifyError(testCase, @() jointMusicRangeDopplerSpectrum( ...
        zeros(5, 4), 2, 3, 32, 64, 12, 1e-3), ...
        'jointMusicRangeDopplerSpectrum:SignalCount');
end

function increment = directJointIncrement(data, bins, spatialOrder, temporalOrder)
    frequencyLags = (-spatialOrder:spatialOrder).';
    increment = complex(zeros(numel(frequencyLags), temporalOrder+1));
    for row = 1:numel(frequencyLags)
        delayedBins = bins-frequencyLags(row);
        [valid, delayedIndex] = ismember(delayedBins, bins);
        currentIndex = valid;
        delayedIndex = delayedIndex(valid);
        for dt = 0:temporalOrder
            increment(row, dt+1) = mean(data(currentIndex, 1) .* ...
                conj(data(delayedIndex, dt+1)));
        end
    end
    increment(spatialOrder+1, 1) = real(increment(spatialOrder+1, 1));
end
