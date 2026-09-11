function [spectrum, eigenvalues, usedLoading, covarianceRcond] = ...
        jointMusicRangeDopplerSpectrum(r, spatialOrder, temporalOrder, ...
        rangePoints, dopplerPoints, signalCount, diagonalLoading)
%JOINTMUSICRANGEDOPPLERSPECTRUM 2-D MUSIC from a joint lag correlation.
%   r contains spatial lags -spatialOrder:spatialOrder in its rows and
%   nonnegative slow-time lags 0:temporalOrder in its columns. A temporary
%   block-Toeplitz covariance is formed for the (spatialOrder+1)-by-
%   (temporalOrder+1) rectangular subarray. No covariance is stored in the
%   recursive state.
%
%   signalCount is the assumed dimension of the target/signal subspace.
%   The returned spectrum is in fftshift spatial/angular-frequency order;
%   its row-to-range mapping is the same as jointArRangeDopplerSpectrum.
    validateattributes(r, {'numeric'}, {'2d', 'finite', 'nonempty'});
    validateattributes(spatialOrder, {'numeric'}, ...
        {'scalar', 'integer', 'positive'});
    validateattributes(temporalOrder, {'numeric'}, ...
        {'scalar', 'integer', 'positive'});
    validateattributes(rangePoints, {'numeric'}, ...
        {'scalar', 'integer', 'positive'});
    validateattributes(dopplerPoints, {'numeric'}, ...
        {'scalar', 'integer', 'positive'});
    validateattributes(signalCount, {'numeric'}, ...
        {'scalar', 'integer', 'positive'});
    validateattributes(diagonalLoading, {'numeric'}, ...
        {'scalar', 'real', 'finite', 'nonnegative'});
    assert(size(r, 1) == 2*spatialOrder+1 && ...
        size(r, 2) == temporalOrder+1, ...
        'jointMusicRangeDopplerSpectrum:CorrelationSize', ...
        'Correlation dimensions do not match the requested aperture.');

    spatialLength = spatialOrder+1;
    temporalLength = temporalOrder+1;
    covarianceSize = spatialLength*temporalLength;
    assert(signalCount < covarianceSize, ...
        'jointMusicRangeDopplerSpectrum:SignalCount', ...
        'Signal count must be smaller than the virtual subarray size.');

    center = spatialOrder+1;
    zeroLagPower = real(r(center, 1));
    spectrum = zeros(rangePoints, dopplerPoints);
    eigenvalues = zeros(covarianceSize, 1);
    usedLoading = diagonalLoading;
    covarianceRcond = 0;
    if zeroLagPower <= 0, return; end

    normalized = r/zeroLagPower;
    [spatialTapGrid, temporalTapGrid] = ndgrid( ...
        0:spatialOrder, 0:temporalOrder);
    spatialTaps = spatialTapGrid(:);
    temporalTaps = temporalTapGrid(:);

    % For y_i=x(m-p_i,n-q_i), E[y_i*conj(y_j)] equals
    % r(p_j-p_i,q_j-q_i). Negative time lags follow Hermitian symmetry.
    covariance = lookupCorrelation(normalized, ...
        spatialTaps.'-spatialTaps, temporalTaps.'-temporalTaps, center);
    covariance = (covariance+covariance')/2;
    [eigenvectors, rawEigenvalues] = eig(covariance, 'vector');
    minimumEigenvalue = min(real(rawEigenvalues));
    usedLoading = max(diagonalLoading, diagonalLoading-minimumEigenvalue);
    loadedCovariance = covariance+usedLoading*eye(covarianceSize);
    covarianceRcond = rcond(loadedCovariance);

    % Scalar diagonal loading shifts eigenvalues but cannot change MUSIC
    % eigenvectors. Return the unshifted eigenvalues so eigengaps remain
    % interpretable; loading/rcond are diagnostics for covariance validity.
    [eigenvalues, order] = sort(real(rawEigenvalues), 'descend');
    signalVectors = eigenvectors(:, order(1:signalCount));

    % a(omega_r,omega_t)=exp(-j*(p*omega_r+q*omega_t)). Using the signal
    % projector is much cheaper than evaluating all noise eigenvectors:
    % a'*En*En'*a = ||a||^2 - a'*Es*Es'*a.
    signalProjection = zeros(rangePoints, dopplerPoints);
    for component = 1:signalCount
        componentWeights = reshape(conj(signalVectors(:, component)), ...
            spatialLength, temporalLength);
        componentResponse = fftshift(fft2( ...
            componentWeights, rangePoints, dopplerPoints));
        signalProjection = signalProjection+abs(componentResponse).^2;
    end
    denominator = covarianceSize-signalProjection;
    denominatorFloor = covarianceSize*eps;
    spectrum = 1./max(real(denominator), denominatorFloor);
end

function values = lookupCorrelation(r, spatialLag, temporalLag, center)
    values = complex(zeros(size(spatialLag)));
    nonnegativeTime = temporalLag >= 0;
    positiveIndex = sub2ind(size(r), ...
        center+spatialLag(nonnegativeTime), ...
        temporalLag(nonnegativeTime)+1);
    values(nonnegativeTime) = r(positiveIndex);
    negativeTime = ~nonnegativeTime;
    negativeIndex = sub2ind(size(r), ...
        center-spatialLag(negativeTime), ...
        -temporalLag(negativeTime)+1);
    values(negativeTime) = conj(r(negativeIndex));
end
