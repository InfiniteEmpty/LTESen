classdef Timebase < handle
%TIMEBASE Single owner of file position and LTE frame/subframe numbering.

    properties (SetAccess = private)
        Epoch = 0
        Sequence = 0
        RawSampleRateHz = NaN
        LteSampleRateHz = NaN
        RawSamplesPerSubframe = NaN
        LteSamplesPerSubframe = NaN
        CurrentRawStartExact = NaN
        FrameNumber = 0
        SubframeNumber = 0
    end

    methods
        function obj = Timebase(lock)
            obj.reset(lock);
        end

        function reset(obj, lock)
            obj.Epoch = double(lock.Epoch);
            obj.Sequence = 0;
            obj.RawSampleRateHz = double(lock.RawSampleRateHz);
            obj.LteSampleRateHz = double(lock.LteSampleRateHz);
            obj.RawSamplesPerSubframe = obj.RawSampleRateHz/1000;
            obj.LteSamplesPerSubframe = round(obj.LteSampleRateHz/1000);
            obj.CurrentRawStartExact = double(lock.RawFrameStartSample0);
            obj.FrameNumber = double(lock.Enb.NFrame);
            obj.SubframeNumber = 0;
        end

        function value = canRead(obj, sampleCount)
            startSample0 = round(obj.CurrentRawStartExact);
            value = startSample0 + round(obj.RawSamplesPerSubframe) <= sampleCount;
        end

        function meta = currentMeta(obj)
            startSample0 = round(obj.CurrentRawStartExact);
            sampleCount = round(obj.RawSamplesPerSubframe);
            meta = struct( ...
                'Epoch', obj.Epoch, ...
                'Sequence', obj.Sequence, ...
                'RawStartSample0', startSample0, ...
                'RawEndSample0', startSample0 + sampleCount, ...
                'RawSampleCount', sampleCount, ...
                'RawSampleRateHz', obj.RawSampleRateHz, ...
                'LteSampleRateHz', obj.LteSampleRateHz, ...
                'TimestampSeconds', startSample0/obj.RawSampleRateHz, ...
                'FrameNumber', obj.FrameNumber, ...
                'SubframeNumber', obj.SubframeNumber);
        end

        function advance(obj, timingDeltaLteSamples)
            if nargin < 2 || isempty(timingDeltaLteSamples)
                timingDeltaLteSamples = 0;
            end
            timingDeltaRawSamples = double(timingDeltaLteSamples) * ...
                obj.RawSampleRateHz/obj.LteSampleRateHz;
            obj.CurrentRawStartExact = obj.CurrentRawStartExact + ...
                obj.RawSamplesPerSubframe + timingDeltaRawSamples;
            obj.Sequence = obj.Sequence + 1;
            obj.SubframeNumber = obj.SubframeNumber + 1;
            if obj.SubframeNumber == 10
                obj.SubframeNumber = 0;
                obj.FrameNumber = mod(obj.FrameNumber + 1, 1024);
            end
        end
    end
end
