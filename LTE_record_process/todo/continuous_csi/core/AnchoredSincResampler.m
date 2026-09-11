classdef AnchoredSincResampler < handle
%ANCHOREDSINCRESAMPLER Resample CSI histories about the latest sample.
%   Input rows are carriers; input columns arrive in chronological order.
%   snapshot returns NEWEST-FIRST columns y_k(j) = x_k(m-alpha_k*j),
%   alpha_k = referenceHz/carrierHz(k), j=0:N-1. The latest column is exact.
%
%   Nearby sinc taps (including the main tap) are evaluated exactly. For
%   |d| > NearRadius, retain sin(pi*delta) exactly and expand 1/(d+delta).
%   Q signed inverse-power sums are updated for RecursiveLength outputs.
%   Longer snapshots use the same raw history and sinc equation directly;
%   this keeps one anchor/state without updating all outputs every sample.
%   No covariance matrix is stored. KernelTolerance bounds the relative
%   truncation error of nonzero far-field weights, NOT finite-history sinc
%   truncation error. Direct long snapshots do not have expansion error.
%   The live anchor has no future-sample support.
%   Assumes the scaled Doppler band remains below slow-time Nyquist; this
%   interpolator does not include an anti-alias low-pass filter.

    properties (SetAccess = private)
        CarrierHz
        ReferenceHz
        Scale
        WindowLength
        RecursiveLength
        HistoryLength
        ExpansionOrder
        NearRadius
        KernelTolerance
        SampleCount = 0
    end

    properties (Access = private)
        RawHistory
        Moments
        AnchorKernel
        EnterKernel
        LeaveKernel
        ExpansionCoefficients
        LocalSource
        LocalOutput
        LocalWeights
    end

    methods
        function obj = AnchoredSincResampler(carrierHz, referenceHz, ...
                windowLength, tolerance, guardSamples, recursiveLength)
            if nargin < 4, tolerance = 1e-8; end
            if nargin < 5, guardSamples = 12; end
            if nargin < 6, recursiveLength = windowLength; end
            validateattributes(carrierHz, {'numeric'}, ...
                {'vector', 'real', 'finite', 'positive', 'nonempty'});
            validateattributes(referenceHz, {'numeric'}, ...
                {'scalar', 'real', 'finite', 'positive'});
            validateattributes(windowLength, {'numeric'}, ...
                {'scalar', 'integer', '>=', 2});
            validateattributes(tolerance, {'numeric'}, ...
                {'scalar', 'real', 'finite', '>', 0, '<', 1});
            validateattributes(guardSamples, {'numeric'}, ...
                {'scalar', 'integer', 'nonnegative'});
            validateattributes(recursiveLength, {'numeric'}, ...
                {'scalar', 'integer', 'positive', '<=', windowLength});

            obj.CarrierHz = double(carrierHz(:));
            obj.ReferenceHz = double(referenceHz);
            obj.Scale = obj.ReferenceHz ./ obj.CarrierHz;
            obj.WindowLength = double(windowLength);
            obj.RecursiveLength = double(recursiveLength);
            obj.KernelTolerance = tolerance;
            N = obj.WindowLength;
            Nr = obj.RecursiveLength;
            K = numel(obj.CarrierHz);
            obj.HistoryLength = max(N, ceil(max(obj.Scale)*(N-1))+1) ...
                + guardSamples;
            M = obj.HistoryLength;
            delta = (obj.Scale-1) * (0:Nr-1);
            maxShift = max(abs(delta), [], 'all');

            % Removing near taps improves convergence even when maxShift>1.
            obj.NearRadius = min(M-1, max(2, ceil(2*maxShift)));
            rho = maxShift / (obj.NearRadius+1);
            assert(rho < 1, 'AnchoredSincResampler:Expansion', ...
                'The far-field expansion must have a ratio smaller than 1.');
            if rho == 0 || obj.NearRadius == M-1
                Q = 1;
            else
                Q = max(1, ceil(log(tolerance)/log(rho)));
            end
            obj.ExpansionOrder = Q;
            obj.RawHistory = complex(zeros(K, M));
            obj.Moments = complex(zeros(K, Nr, Q));
            obj.AnchorKernel = zeros(M, Q);
            obj.EnterKernel = zeros(1, Nr-1, Q);
            obj.LeaveKernel = zeros(1, Nr-1, Q);
            obj.ExpansionCoefficients = zeros(K, Nr, Q);
            for q = 1:Q
                obj.AnchorKernel(:, q) = obj.farKernel(-(0:M-1).', q);
                obj.EnterKernel(1, :, q) = obj.farKernel(1:Nr-1, q);
                obj.LeaveKernel(1, :, q) = obj.farKernel((1:Nr-1)-M, q);
                obj.ExpansionCoefficients(:, :, q) = ...
                    sinpi(delta)/pi .* (-delta).^(q-1);
            end

            offsets = -obj.NearRadius:obj.NearRadius;
            obj.LocalSource = cell(size(offsets));
            obj.LocalOutput = cell(size(offsets));
            obj.LocalWeights = cell(size(offsets));
            for tap = 1:numel(offsets)
                source = (0:Nr-1) + offsets(tap);
                valid = source >= 0 & source < M;
                obj.LocalSource{tap} = source(valid)+1;
                obj.LocalOutput{tap} = find(valid);
                obj.LocalWeights{tap} = obj.exactSinc( ...
                    delta(:, valid)-offsets(tap));
            end
        end

        function push(obj, samples)
            validateattributes(samples, {'numeric'}, {'2d', 'finite'});
            assert(size(samples, 1) == numel(obj.CarrierHz), ...
                'AnchoredSincResampler:CarrierCount', ...
                'Input rows must match the carrier frequencies.');
            for t = 1:size(samples, 2)
                newest = double(samples(:, t));
                oldest = obj.RawHistory(:, end);
                obj.RawHistory(:, 2:end) = obj.RawHistory(:, 1:end-1);
                obj.RawHistory(:, 1) = newest;
                obj.Moments(:, 2:end, :) = obj.Moments(:, 1:end-1, :) ...
                    + newest .* obj.EnterKernel - oldest .* obj.LeaveKernel;
                obj.Moments(:, 1, :) = reshape( ...
                    obj.RawHistory * obj.AnchorKernel, ...
                    numel(obj.CarrierHz), 1, obj.ExpansionOrder);
                obj.SampleCount = obj.SampleCount+1;
            end
        end

        function [aligned, original] = snapshot(obj, outputLength)
            if nargin < 2, outputLength = obj.WindowLength; end
            validateattributes(outputLength, {'numeric'}, ...
                {'scalar', 'integer', 'positive', '<=', obj.WindowLength});
            assert(obj.SampleCount >= obj.HistoryLength, ...
                'AnchoredSincResampler:Warmup', ...
                'Wait until the complete interpolation history is available.');
            if outputLength <= obj.RecursiveLength
                aligned = sum(obj.Moments(:, 1:outputLength, :) .* ...
                    obj.ExpansionCoefficients(:, 1:outputLength, :), 3);
                for tap = 1:numel(obj.LocalSource)
                    output = obj.LocalOutput{tap};
                    use = output <= outputLength;
                    output = output(use);
                    aligned(:, output) = aligned(:, output) ...
                        + obj.LocalWeights{tap}(:, use) .* ...
                        obj.RawHistory(:, obj.LocalSource{tap}(use));
                end
            else
                % Long snapshots are requested only at the display cadence.
                % Evaluate the same finite-history sinc interpolator directly,
                % avoiding O(WindowLength) moment updates at every input sample.
                aligned = complex(zeros(numel(obj.CarrierHz), outputLength));
                rawCoordinates = 0:obj.HistoryLength-1;
                for carrier = 1:numel(obj.CarrierHz)
                    coordinates = obj.Scale(carrier)*(0:outputLength-1).' ...
                        - rawCoordinates;
                    weights = obj.exactSinc(coordinates);
                    aligned(carrier, :) = ...
                        (weights*obj.RawHistory(carrier, :).').';
                end
            end
            aligned(:, 1) = obj.RawHistory(:, 1);
            original = obj.RawHistory(:, 1:outputLength);
        end
    end

    methods (Access = private)
        function h = farKernel(obj, d, q)
            h = zeros(size(d));
            far = abs(d) > obj.NearRadius;
            h(far) = (-1).^d(far) ./ d(far).^q;
        end
    end

    methods (Static, Access = private)
        function y = exactSinc(x)
            y = ones(size(x));
            nonzero = x ~= 0;
            y(nonzero) = sinpi(x(nonzero)) ./ (pi*x(nonzero));
        end
    end
end
