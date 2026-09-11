function [psd, coefficients, predictionError, usedLoading, fitRcond] = ...
        jointArRangeDopplerSpectrum(r, spatialOrder, temporalOrder, ...
        rangePoints, dopplerPoints, diagonalLoading)
%JOINTARRANGEDOPPLERSPECTRUM Quadrant-causal 2-D Yule-Walker AR spectrum.
%   r rows are spatial lags -spatialOrder:spatialOrder and columns are
%   nonnegative temporal lags 0:temporalOrder. Predictor taps occupy the
%   rectangle df=0:spatialOrder, dt=0:temporalOrder excluding (0,0).
%   The regularized normal matrix is formed only while fitting; it is not a
%   persistent covariance state. 2-D AR stability is not implied by this fit.
    validateattributes(r, {'numeric'}, {'2d', 'finite', 'nonempty'});
    validateattributes(spatialOrder, {'numeric'}, ...
        {'scalar', 'integer', 'positive'});
    validateattributes(temporalOrder, {'numeric'}, ...
        {'scalar', 'integer', 'positive'});
    validateattributes(rangePoints, {'numeric'}, {'scalar', 'integer', 'positive'});
    validateattributes(dopplerPoints, {'numeric'}, {'scalar', 'integer', 'positive'});
    validateattributes(diagonalLoading, {'numeric'}, ...
        {'scalar', 'real', 'finite', 'nonnegative'});
    assert(size(r, 1) == 2*spatialOrder+1 && ...
        size(r, 2) == temporalOrder+1, ...
        'jointArRangeDopplerSpectrum:CorrelationSize', ...
        'Correlation dimensions do not match the requested model orders.');
    center = spatialOrder+1;
    power = real(r(center, 1));
    psd = zeros(rangePoints, dopplerPoints);
    coefficients = complex(zeros(spatialOrder+1, temporalOrder+1));
    coefficients(1, 1) = 1;
    predictionError = 0;
    usedLoading = diagonalLoading;
    fitRcond = 0;
    if power <= 0, return; end
    normalized = r/power;

    [dfGrid, dtGrid] = ndgrid(0:spatialOrder, 0:temporalOrder);
    keep = ~(dfGrid == 0 & dtGrid == 0);
    tapDf = dfGrid(keep);
    tapDt = dtGrid(keep);
    g = lookupCorrelation(normalized, tapDf, tapDt, center);
    differenceDf = tapDf-tapDf.';
    differenceDt = tapDt-tapDt.';
    normalMatrix = lookupCorrelation(normalized, ...
        differenceDf, differenceDt, center);
    normalMatrix = (normalMatrix+normalMatrix')/2;
    minimumEigenvalue = min(real(eig(normalMatrix, 'vector')));
    usedLoading = max(diagonalLoading, diagonalLoading-minimumEigenvalue);
    loadedMatrix = normalMatrix+usedLoading*eye(size(normalMatrix));
    fitRcond = rcond(loadedMatrix);
    assert(isfinite(fitRcond) && fitRcond > eps, ...
        'jointArRangeDopplerSpectrum:SingularFit', ...
        'The loaded 2-D Yule-Walker system is numerically singular.');
    a = -loadedMatrix\g;
    coefficients(keep) = a;

    covarianceMatrix = normalMatrix.';
    errorNormalized = real(1 + 2*a.'*conj(g) + ...
        a.'*covarianceMatrix*conj(a));
    predictionError = power*max(errorNormalized, eps);
    denominator = fftshift(fft2(coefficients, rangePoints, dopplerPoints));
    denominatorFloor = eps*sum(abs(coefficients), 'all')^2;
    psd = predictionError ./ max(abs(denominator).^2, denominatorFloor);
end

function values = lookupCorrelation(r, df, dt, center)
    values = complex(zeros(size(df)));
    positiveTime = dt >= 0;
    positiveIndex = sub2ind(size(r), center+df(positiveTime), dt(positiveTime)+1);
    values(positiveTime) = r(positiveIndex);
    negativeTime = ~positiveTime;
    negativeIndex = sub2ind(size(r), center-df(negativeTime), -dt(negativeTime)+1);
    values(negativeTime) = conj(r(negativeIndex));
end
