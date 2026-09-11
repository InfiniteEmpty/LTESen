classdef CfoTracker < handle
%CFOTRACKER Recursive cyclic-prefix CFO estimation and correction.

    properties (SetAccess = private)
        Config
        CfoHz = 0
        ResidualCfoHz = NaN
        LastCpCorrelation = NaN
    end

    properties (Access = private)
        Nfft
        CpLengths
        SampleRateHz
        TimeSeconds
    end

    methods
        function obj = CfoTracker(config, lock)
            obj.Config = config;
            obj.setup(lock);
        end

        function setup(obj, lock)
            obj.Nfft = double(lock.OfdmInfo.Nfft);
            obj.CpLengths = double(lock.OfdmInfo.CyclicPrefixLengths);
            obj.SampleRateHz = double(lock.LteSampleRateHz);
            sampleCount = round(obj.SampleRateHz/1000);
            obj.TimeSeconds = (0:sampleCount-1).'/obj.SampleRateHz;
            obj.CfoHz = double(lock.InitialCfoHz);
            obj.ResidualCfoHz = NaN;
            obj.LastCpCorrelation = NaN;
        end

        function [corrected, quality] = correct(obj, waveform)
            validateattributes(waveform, {'numeric'}, ...
                {'2d', 'nonempty', 'finite'});
            if size(waveform, 1) ~= numel(obj.TimeSeconds)
                error('ltetracking:CfoTracker:SampleCount', ...
                    'Expected %d LTE samples, received %d.', ...
                    numel(obj.TimeSeconds), size(waveform, 1));
            end
            coarseCorrection = exp(-2i*pi*obj.CfoHz*obj.TimeSeconds);
            coarseWaveform = waveform .* coarseCorrection;

            frontStart = double(obj.Config.CfoCpStartSample);
            tailStart = frontStart + obj.Nfft;
            mixedSum = complex(0);
            normalization = 0;
            for cpLength = obj.CpLengths
                cpUse = cpLength - double(obj.Config.CfoCpGuardSamples);
                if cpUse <= 0 || tailStart+cpUse-1 > size(coarseWaveform, 1)
                    error('ltetracking:CfoTracker:InvalidCpWindow', ...
                        'The configured CP correlation window is invalid.');
                end
                front = coarseWaveform( ...
                    frontStart:frontStart+cpUse-1, 1);
                tail = coarseWaveform(tailStart:tailStart+cpUse-1, 1);
                mixedSum = mixedSum + sum(tail .* conj(front));
                normalization = normalization + sqrt( ...
                    sum(abs(front).^2)*sum(abs(tail).^2));
                frontStart = frontStart + obj.Nfft + cpLength;
                tailStart = tailStart + obj.Nfft + cpLength;
            end

            radiansToHz = obj.SampleRateHz/obj.Nfft/(2*pi);
            obj.ResidualCfoHz = angle(mixedSum)*radiansToHz;
            obj.CfoHz = obj.CfoHz + obj.ResidualCfoHz;
            obj.LastCpCorrelation = abs(mixedSum)/max(normalization, eps);
            corrected = waveform .* exp( ...
                -2i*pi*obj.CfoHz*obj.TimeSeconds);
            quality = struct( ...
                'CfoHz', obj.CfoHz, ...
                'ResidualCfoHz', obj.ResidualCfoHz, ...
                'CpCorrelation', obj.LastCpCorrelation);
        end

        function status = getStatus(obj)
            status = struct('State', 'ready', 'Ready', true, ...
                'CfoHz', obj.CfoHz, ...
                'ResidualCfoHz', obj.ResidualCfoHz, ...
                'CpCorrelation', obj.LastCpCorrelation);
        end
    end
end
