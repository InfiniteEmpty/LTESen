classdef Acquirer < handle
%ACQUIRER Initial LTE cell search, MIB decode, and full-band lock.

    properties (SetAccess = private)
        Config
    end

    methods
        function obj = Acquirer(config)
            obj.Config = config;
        end

        function lock = acquire(obj, dataFile, epoch, headStartSample0)
            if nargin < 3
                epoch = 1;
            end
            if nargin < 4 || isempty(headStartSample0)
                headStartSample0 = double(obj.Config.HeadStartSample0);
            end
            rawSampleRateHz = double(dataFile.sample_rate);
            headStartSample0 = max(0, round(double(headStartSample0)));
            searchSampleCount = round( ...
                obj.Config.SearchDurationSeconds*rawSampleRateHz);
            headWaveform = dataFile.readAt( ...
                headStartSample0, searchSampleCount, true);
            if isempty(headWaveform)
                error('ltesync:Acquirer:EmptySignal', ...
                    'The acquisition waveform is empty.');
            end

            enb = struct('NDLRB', obj.Config.InitialNDLRB);
            searchOfdmInfo = lteOFDMInfo(setfield( ...
                enb, 'CyclicPrefix', 'Normal')); %#ok<SFLD>
            searchWaveform = obj.resampleWaveform(headWaveform, ...
                rawSampleRateHz, double(searchOfdmInfo.SamplingRate));

            duplexModes = {'TDD', 'FDD'};
            cyclicPrefixes = {'Normal', 'Extended'};
            searchAlgorithm = struct( ...
                'MaxCellCount', obj.Config.MaxCellCount, ...
                'SSSDetection', obj.Config.SSSDetection);
            bestPeak = -Inf;
            bestEnb = struct();
            bestOffset = NaN;
            for duplexIndex = 1:numel(duplexModes)
                for cpIndex = 1:numel(cyclicPrefixes)
                    candidate = enb;
                    candidate.DuplexMode = duplexModes{duplexIndex};
                    candidate.CyclicPrefix = cyclicPrefixes{cpIndex};
                    [cellId, timingOffset, peak] = lteCellSearch( ...
                        candidate, searchWaveform, searchAlgorithm);
                    if isempty(cellId) || isempty(timingOffset) || isempty(peak)
                        continue;
                    end
                    candidate.NCellID = cellId(1);
                    if peak(1) > bestPeak
                        bestPeak = peak(1);
                        bestEnb = candidate;
                        bestOffset = timingOffset(1);
                    end
                end
            end
            if isempty(fieldnames(bestEnb)) || ~isfinite(bestOffset)
                error('ltesync:Acquirer:CellSearchFailed', ...
                    'LTE cell search did not return a valid cell.');
            end
            enb = bestEnb;

            [correlation, peakRatio] = obj.measureCellCorrelation( ...
                enb, searchWaveform);
            searchWaveform = searchWaveform(1+bestOffset:end, :);
            enb.NSubframe = 0;
            if strcmpi(enb.DuplexMode, 'TDD')
                enb.TDDConfig = 0;
                enb.SSC = 0;
            end

            initialCfoHz = lteFrequencyOffset(enb, searchWaveform);
            searchWaveform = lteFrequencyCorrect( ...
                enb, searchWaveform, initialCfoHz);
            cec = struct('PilotAverage', 'UserDefined', ...
                'FreqWindow', 13, 'TimeWindow', 9, ...
                'InterpType', 'cubic', 'InterpWindow', 'Centered', ...
                'InterpWinSize', 1);
            enb.CellRefP = 4;
            gridDimensions = lteResourceGridSize(enb);
            symbolsPerSubframe = gridDimensions(2);
            resourceGrid = lteOFDMDemodulate(enb, searchWaveform);
            if size(resourceGrid, 2) < symbolsPerSubframe
                error('ltesync:Acquirer:ShortSignal', ...
                    'The synchronized acquisition signal is shorter than one subframe.');
            end
            [channelEstimate, noiseEstimate] = lteDLChannelEstimate( ...
                enb, cec, resourceGrid(:, 1:symbolsPerSubframe, :));
            pbchIndices = ltePBCHIndices(enb);
            [pbchRx, pbchHest] = lteExtractResources(pbchIndices, ...
                resourceGrid(:, 1:symbolsPerSubframe, :), ...
                channelEstimate(:, 1:symbolsPerSubframe, :, :));
            [~, ~, frameModulo4, mib, enb.CellRefP] = ltePBCHDecode( ...
                enb, pbchRx, pbchHest, noiseEstimate);
            enb = lteMIB(mib, enb);
            enb.NFrame = enb.NFrame + frameModulo4;
            if enb.CellRefP == 0 || enb.NDLRB == 0
                error('ltesync:Acquirer:MibDecodeFailed', ...
                    'MIB decoding failed during acquisition.');
            end

            ofdmInfo = lteOFDMInfo(enb);
            lteSampleRateHz = double(ofdmInfo.SamplingRate);
            fullBandwidthWaveform = obj.resampleWaveform( ...
                headWaveform, rawSampleRateHz, lteSampleRateHz);
            initialCfoHz = lteFrequencyOffset(enb, fullBandwidthWaveform);
            correctedWaveform = lteFrequencyCorrect( ...
                enb, fullBandwidthWaveform, initialCfoHz);
            frameOffsetLteSamples = lteDLFrameOffset(enb, correctedWaveform);
            frameOffsetRawSamples = round( ...
                double(frameOffsetLteSamples)*rawSampleRateHz/lteSampleRateHz);

            lock = struct();
            lock.Epoch = double(epoch);
            lock.Enb = enb;
            lock.OfdmInfo = ofdmInfo;
            lock.RawSampleRateHz = rawSampleRateHz;
            lock.LteSampleRateHz = lteSampleRateHz;
            lock.RawFrameStartSample0 = headStartSample0 + frameOffsetRawSamples;
            lock.InitialCfoHz = double(initialCfoHz);
            lock.ReceiveAntennaCount = size(headWaveform, 2);
            lock.Diagnostics = struct();
            lock.Diagnostics.CellSearchPeak = double(bestPeak);
            lock.Diagnostics.PssCorrelation = correlation;
            lock.Diagnostics.PssPeakRatio = double(peakRatio);
            lock.Diagnostics.FrameOffsetLteSamples = ...
                double(frameOffsetLteSamples);
            lock.Diagnostics.FrameOffsetRawSamples = ...
                double(frameOffsetRawSamples);
        end
    end

    methods (Static, Access = private)
        function output = resampleWaveform(input, inputRate, outputRate)
            if inputRate == outputRate
                output = input;
                return;
            end
            outputLength = ceil(outputRate/inputRate*size(input, 1));
            output = zeros(outputLength, size(input, 2));
            for antenna = 1:size(input, 2)
                values = resample(input(:, antenna), outputRate, inputRate);
                output(1:min(outputLength, numel(values)), antenna) = ...
                    values(1:min(outputLength, numel(values)));
            end
        end

        function [correlation, peakRatio] = measureCellCorrelation(enb, waveform)
            correlation = cell(1, 3);
            identityGroup = floor(enb.NCellID/3);
            selectedPeak = NaN;
            competingPeak = 0;
            originalCellId = enb.NCellID;
            for identity = 0:2
                candidate = enb;
                candidate.NCellID = identityGroup*3 + ...
                    mod(originalCellId + identity, 3);
                [~, values] = lteDLFrameOffset(candidate, waveform);
                values = sum(values, 2);
                correlation{identity+1} = values;
                if identity == 0
                    selectedPeak = max(values);
                else
                    competingPeak = max(competingPeak, max(values));
                end
            end
            peakRatio = selectedPeak/max(competingPeak, eps);
        end
    end
end
