function tests = test_AnchoredDopplerSpectra
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

function testRecursiveSincAndAnchor(testCase)
    rng(51);
    fc = 3.2e9;
    carrierHz = fc+[-9e6; 0; 9e6];
    obj = AnchoredSincResampler(carrierHz, fc, 200, 1e-10, 12);
    data = randn(3, 700)+1i*randn(3, 700);
    verifyError(testCase, @() obj.snapshot(), 'AnchoredSincResampler:Warmup');
    maxError = 0;
    for t = 1:2:size(data, 2)
        obj.push(data(:, t:t+1));
        if obj.SampleCount >= obj.HistoryLength && mod(t+1, 50) == 0
            [actual, original] = obj.snapshot();
            history = data(:, t+1:-1:t+2-obj.HistoryLength);
            expected = directSinc(history, obj.Scale, obj.WindowLength);
            maxError = max(maxError, norm(actual-expected, 'fro')/norm(expected, 'fro'));
            verifyEqual(testCase, actual(:, 1), data(:, t+1));
            verifyEqual(testCase, original, history(:, 1:obj.WindowLength));
            verifyEqual(testCase, actual(2, :), original(2, :), 'AbsTol', 1e-13);
        end
    end
    fprintf('Recursive sinc maximum relative error: %.3g (Q=%d)\n', ...
        maxError, obj.ExpansionOrder);
    verifyLessThan(testCase, maxError, 1e-9);
end

function testOffsetsLargerThanOneAndChunking(testCase)
    rng(52);
    fc = 3.2e9;
    frequencies = fc./[0.985; 1.015];
    a = AnchoredSincResampler(frequencies, fc, 100, 1e-10, 10);
    b = AnchoredSincResampler(frequencies, fc, 100, 1e-10, 10);
    data = randn(2, 320)+1i*randn(2, 320);
    a.push(data);
    for t = 1:320, b.push(data(:, t)); end
    [actual, ~] = a.snapshot();
    verifyEqual(testCase, actual, b.snapshot());
    history = data(:, end:-1:end-a.HistoryLength+1);
    expected = directSinc(history, a.Scale, a.WindowLength);
    verifyLessThan(testCase, norm(actual-expected, 'fro')/norm(expected, 'fro'), 1e-9);
end

function testPartialSnapshotMatchesFullPrefix(testCase)
    rng(53);
    fc = 3.2e9;
    carrierHz = fc+[-9e6; 0; 9e6];
    obj = AnchoredSincResampler(carrierHz, fc, 200, 1e-10, 12);
    obj.push(randn(3, 350)+1i*randn(3, 350));
    full = obj.snapshot();
    for outputLength = [1 7 25 199]
        [partial, original] = obj.snapshot(outputLength);
        verifyEqual(testCase, partial, full(:, 1:outputLength), 'AbsTol', 1e-13);
        verifySize(testCase, original, [3 outputLength]);
    end
end

function testRangeDopplerAxesAndDcGap(testCase)
    fc = 3.2e9;
    df = 15e3;
    active = [-600:-1 1:600]*df;
    offsets = active(4:6:end).';
    N = 200;
    Nr = 2048;
    Nd = 800;
    Ts = 5e-4;
    rangeResolution = 299792458/(2*df*Nr);
    for target = [12, -7; -200, 175]
        range = target(1)*rangeResolution;
        fd = target(2);
        data = exp(-2i*pi*(fc+offsets)*(2*range/299792458)) ...
            .* exp(-2i*pi*fd*Ts*(0:N-1));
        [rd, ranges, frequencies] = anchoredRangeDopplerFFT( ...
            data, offsets, df, Nr, Nd, Ts);
        [peak, linear] = max(rd(:));
        [ir, iv] = ind2sub(size(rd), linear);
        verifyEqual(testCase, ranges(ir), range, 'AbsTol', 1e-10);
        verifyEqual(testCase, frequencies(iv), fd, 'AbsTol', 1e-10);
        verifyEqual(testCase, peak, 1, 'AbsTol', 1e-10);
    end
end

function testPhysicalMovingTarget(testCase)
    fc = 3.2e9;
    df = 15e3;
    active = [-600:-1 1:600]*df;
    offsets = active(4:48:end).';
    Ts = 5e-4;
    fd = -250;
    velocity = -fd*299792458/(2*fc);
    time = (0:399)*Ts;
    currentRange = 60+velocity*time(end);
    data = exp(-2i*pi*(fc+offsets)*(2*(60+velocity*time)/299792458));
    obj = AnchoredSincResampler(fc+offsets, fc, 200, 1e-10, 12);
    obj.push(data);
    aligned = obj.snapshot();
    expected = exp(-2i*pi*(fc+offsets)*(2*currentRange/299792458)) ...
        .* exp(-2i*pi*fd*Ts*(0:199));
    % Finite causal sinc support, unlike recursion truncation, has an edge error.
    interior = 11:180;
    relativeError = norm(aligned(:, interior)-expected(:, interior), 'fro') ...
        / norm(expected(:, interior), 'fro');
    fprintf('Moving-target finite-sinc interior error: %.3g\n', relativeError);
    verifyLessThan(testCase, relativeError, 0.01);
    verifyEqual(testCase, aligned(:, 1), data(:, end));
end

function result = directSinc(history, scale, N)
    result = complex(zeros(size(history, 1), N));
    for k = 1:size(history, 1)
        coordinates = scale(k)*(0:N-1).'-(0:size(history, 2)-1);
        weights = ones(size(coordinates));
        nonzero = coordinates ~= 0;
        weights(nonzero) = sinpi(coordinates(nonzero))./(pi*coordinates(nonzero));
        result(k, :) = (weights*history(k, :).').';
    end
end
