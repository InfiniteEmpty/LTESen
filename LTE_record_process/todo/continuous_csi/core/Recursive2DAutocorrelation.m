classdef Recursive2DAutocorrelation < handle
%RECURSIVE2DAUTOCORRELATION Joint carrier-lag/slow-time-lag accumulator.
%   Each input is a K-by-(TemporalOrder+1) current-anchor CSI snapshot.
%   Rows are actual measured carrier frequencies; columns are newest-first
%   aligned slow-time lags. For every new sample this class jointly forms
%       q(df,dt) = mean_f x(f,n)*conj(x(f-df*DeltaF,n-dt))
%   and applies one exponential update. It never first collapses either
%   dimension, and it stores no sample covariance matrix.

    properties (SetAccess = private)
        TemporalOrder
        SpatialOrder
        SpatialSpacingHz
        CarrierCount
        FrequencyLags
        ForgettingFactor
        SampleCount = 0
        Numerator
        Weight = 0
        Correlation
        LastIncrement
        PairCount
    end

    properties (Access = private)
        CurrentIndex
        DelayedIndex
        PairMask
    end

    methods
        function obj = Recursive2DAutocorrelation(carrierHz, spatialSpacingHz, ...
                spatialOrder, temporalOrder, forgettingFactor)
            validateattributes(carrierHz, {'numeric'}, ...
                {'vector', 'real', 'finite', 'nonempty'});
            validateattributes(spatialSpacingHz, {'numeric'}, ...
                {'scalar', 'real', 'finite', 'positive'});
            validateattributes(spatialOrder, {'numeric'}, ...
                {'scalar', 'integer', 'positive'});
            validateattributes(temporalOrder, {'numeric'}, ...
                {'scalar', 'integer', 'positive'});
            validateattributes(forgettingFactor, {'numeric'}, ...
                {'scalar', 'real', 'finite', '>', 0, '<=', 1});
            frequencies = double(carrierHz(:));
            assert(issorted(frequencies, 'strictascend'), ...
                'Recursive2DAutocorrelation:CarrierOrder', ...
                'Carrier frequencies must be strictly increasing.');
            obj.TemporalOrder = temporalOrder;
            obj.SpatialOrder = spatialOrder;
            obj.SpatialSpacingHz = spatialSpacingHz;
            obj.CarrierCount = numel(frequencies);
            obj.FrequencyLags = (-spatialOrder:spatialOrder).';
            obj.ForgettingFactor = forgettingFactor;
            nLag = numel(obj.FrequencyLags);
            obj.Numerator = complex(zeros(nLag, temporalOrder+1));
            obj.Correlation = obj.Numerator;
            obj.LastIncrement = obj.Numerator;

            % Pair actual frequencies. A missing DC/CRS sample is skipped;
            % row adjacency is never substituted for a physical DeltaF lag.
            currentCell = cell(nLag, 1);
            delayedCell = cell(nLag, 1);
            count = zeros(nLag, 1);
            toleranceHz = max(1e-3, 32*eps(max(abs(frequencies))));
            for row = 1:nLag
                target = frequencies-obj.FrequencyLags(row)*spatialSpacingHz;
                [matched, location] = ismembertol(target, frequencies, ...
                    toleranceHz, 'DataScale', 1);
                currentCell{row} = find(matched);
                delayedCell{row} = location(matched);
                count(row) = nnz(matched);
            end
            assert(all(count > 0), 'Recursive2DAutocorrelation:SpatialOrder', ...
                'Spatial order is too large for the measured carrier set.');
            obj.PairCount = count;
            maxPairCount = max(count);
            obj.CurrentIndex = ones(nLag, maxPairCount);
            obj.DelayedIndex = ones(nLag, maxPairCount);
            obj.PairMask = false(nLag, maxPairCount);
            for row = 1:nLag
                columns = 1:count(row);
                obj.CurrentIndex(row, columns) = currentCell{row};
                obj.DelayedIndex(row, columns) = delayedCell{row};
                obj.PairMask(row, columns) = true;
            end
        end

        function push(obj, alignedLags)
            validateattributes(alignedLags, {'numeric'}, {'2d', 'finite', 'nonempty'});
            assert(size(alignedLags, 2) >= obj.TemporalOrder+1, ...
                'Recursive2DAutocorrelation:TemporalLags', ...
                'Not enough aligned slow-time lag columns.');
            assert(size(alignedLags, 1) == obj.CarrierCount, ...
                'Recursive2DAutocorrelation:CarrierCount', ...
                'Input rows do not match the configured carriers.');
            data = double(alignedLags);
            current = data(:, 1);
            increment = complex(zeros(size(obj.Numerator)));
            for dt = 0:obj.TemporalOrder
                delayed = data(:, dt+1);
                products = current(obj.CurrentIndex) .* ...
                    conj(delayed(obj.DelayedIndex));
                products(~obj.PairMask) = 0;
                increment(:, dt+1) = sum(products, 2)./obj.PairCount;
            end
            zeroSpatial = obj.SpatialOrder+1;
            increment(zeroSpatial, 1) = real(increment(zeroSpatial, 1));
            obj.LastIncrement = increment;
            obj.Numerator = obj.ForgettingFactor*obj.Numerator+increment;
            obj.Weight = obj.ForgettingFactor*obj.Weight+1;
            obj.Correlation = obj.Numerator/obj.Weight;
            obj.SampleCount = obj.SampleCount+1;
        end
    end
end
