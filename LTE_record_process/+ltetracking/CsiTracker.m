classdef CsiTracker < handle
%CSITRACKER Correct CSI phase/SFO and maintain the static CSI estimate.

    properties (SetAccess = private)
        Config
        SampleCount = 0
        LastTimingDeltaLteSamples = 0
        LastSampleShift = NaN
    end

    properties (Access = private)
        Nfft
        CarrierCount
        Ncrs
        Nrx
        Ntx
        FilterB
        FilterA
        FilterStateG1
        FilterStateG2
        StaticG1
        StaticG2
    end

    methods
        function obj = CsiTracker(config, context)
            obj.Config = config;
            obj.setup(context);
        end

        function setup(obj, context)
            obj.Nfft = double(context.OfdmInfo.Nfft);
            obj.CarrierCount = double(context.Enb.NDLRB*12);
            obj.Ncrs = double(context.Enb.NDLRB*2);
            obj.Nrx = double(context.ReceiveAntennaCount);
            obj.Ntx = double(context.Enb.CellRefP);
            [obj.FilterB, obj.FilterA] = butter( ...
                obj.Config.StaticFilterOrder, ...
                obj.Config.StaticFilterCutoff, 'low');
            filterOrder = max(numel(obj.FilterA), numel(obj.FilterB))-1;
            stateSize = [filterOrder, obj.Ncrs, obj.Nrx, obj.Ntx];
            obj.FilterStateG1 = zeros(stateSize);
            obj.FilterStateG2 = zeros(stateSize);
            obj.StaticG1 = ones(obj.Ncrs, 1, obj.Nrx, obj.Ntx);
            obj.StaticG2 = ones(obj.Ncrs, 1, obj.Nrx, obj.Ntx);
            obj.SampleCount = 0;
            obj.LastTimingDeltaLteSamples = 0;
            obj.LastSampleShift = NaN;
        end

        function [data, quality] = correct(obj, csiG1, csiG2, indexG1, indexG2)
            obj.validateInput(csiG1, csiG2);
            frequencyG1 = reshape( ...
                indexG1(:, 1)-obj.CarrierCount/2, [], 1, 1, 1);
            frequencyG2 = reshape( ...
                indexG2(:, 1)-obj.CarrierCount/2, [], 1, 1, 1);
            if obj.SampleCount == 0
                obj.StaticG1 = csiG1(:, 1, :, :);
                obj.StaticG2 = csiG2(:, 1, :, :);
            end

            dynamicG1 = complex(zeros(size(csiG1), 'like', csiG1));
            dynamicG2 = complex(zeros(size(csiG2), 'like', csiG2));
            sampleShiftG1 = zeros(1, size(csiG1, 2));
            sampleShiftG2 = zeros(1, size(csiG2, 2));
            for timeIndex = 1:size(csiG1, 2)
                [csiG1(:, timeIndex, :, :), dynamicG1(:, timeIndex, :, :), ...
                    obj.StaticG1, obj.FilterStateG1, sampleShiftG1(timeIndex)] = ...
                    obj.correctOne(csiG1(:, timeIndex, :, :), ...
                    obj.StaticG1, obj.FilterStateG1, frequencyG1);
                [csiG2(:, timeIndex, :, :), dynamicG2(:, timeIndex, :, :), ...
                    obj.StaticG2, obj.FilterStateG2, sampleShiftG2(timeIndex)] = ...
                    obj.correctOne(csiG2(:, timeIndex, :, :), ...
                    obj.StaticG2, obj.FilterStateG2, frequencyG2);
            end
            obj.LastSampleShift = mean( ...
                [sampleShiftG1, sampleShiftG2], 'all');
            obj.LastTimingDeltaLteSamples = -round(obj.LastSampleShift);
            obj.SampleCount = obj.SampleCount + 1;

            data = struct('G1', csiG1, 'G2', csiG2, ...
                'DynamicG1', dynamicG1, 'DynamicG2', dynamicG2, ...
                'CarrierIndicesG1', indexG1, ...
                'CarrierIndicesG2', indexG2);
            quality = struct( ...
                'SampleShift', obj.LastSampleShift, ...
                'TimingDeltaLteSamples', obj.LastTimingDeltaLteSamples, ...
                'StaticEstimateReady', obj.SampleCount > 1);
        end

        function status = getStatus(obj)
            status = struct( ...
                'State', obj.readyState(), ...
                'Ready', obj.SampleCount > 1, ...
                'WarmupCount', min(obj.SampleCount, 2), ...
                'WarmupRequired', 2, ...
                'LastSampleShift', obj.LastSampleShift, ...
                'LastTimingDeltaLteSamples', ...
                obj.LastTimingDeltaLteSamples);
        end
    end

    methods (Access = private)
        function [corrected, dynamic, staticEstimate, filterState, shift] = ...
                correctOne(obj, input, staticEstimate, filterState, frequency)
            scale = vecnorm(input);
            scale(scale == 0) = 1;
            normalized = input ./ scale;
            difference = normalized .* conj(staticEstimate);
            shiftTensor = ltetracking.estimatePhaseSlopeFFT(difference) * ...
                obj.Nfft/obj.CarrierCount;
            correction = exp(-2i*pi/obj.Nfft * shiftTensor .* frequency);
            phaseBias = angle(sum(difference .* correction, 1));
            corrected = normalized .* correction .* exp(-1i*phaseBias);
            currentRow = permute(corrected, [2, 1, 3, 4]);
            [staticRow, filterState] = filter(obj.FilterB, obj.FilterA, ...
                currentRow, filterState, 1);
            staticEstimate = permute(staticRow, [2, 1, 3, 4]);
            dynamic = corrected-staticEstimate;
            shift = mean(shiftTensor, 'all');
        end

        function validateInput(obj, csiG1, csiG2)
            actualG1 = [size(csiG1, 1), size(csiG1, 2), ...
                size(csiG1, 3), size(csiG1, 4)];
            actualG2 = [size(csiG2, 1), size(csiG2, 2), ...
                size(csiG2, 3), size(csiG2, 4)];
            expected = [obj.Ncrs, 2, obj.Nrx, obj.Ntx];
            if ~isequal(actualG1, expected) || ~isequal(actualG2, expected)
                error('ltetracking:CsiTracker:InputSize', ...
                    'CSI dimensions do not match the receiver context.');
            end
        end

        function value = readyState(obj)
            if obj.SampleCount > 1
                value = 'ready';
            else
                value = 'warming';
            end
        end
    end
end
