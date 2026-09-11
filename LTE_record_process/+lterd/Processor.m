classdef Processor < handle
%PROCESSOR Build contiguous CSI windows and calculate range-Doppler maps.

    properties (SetAccess = private)
        Config
        Context
        Epoch = NaN
        OutputCount = 0
        NoiseFloorDb = NaN
    end

    properties (Access = private)
        Window
    end

    methods
        function obj = Processor(config, context)
            obj.Config = config;
            obj.Context = context;
            obj.Window = ltebuffer.FrameWindow( ...
                config.WindowFrames, config.HopFrames);
        end

        function result = push(obj, framePacket)
            result = obj.emptyResult();
            if obj.Config.RequireCancellationReady && ...
                    (~isfield(framePacket.Meta, 'CancellationReady') || ...
                    ~framePacket.Meta.CancellationReady)
                return;
            end
            if ~isequal(obj.Epoch, framePacket.Meta.Epoch)
                obj.reset(framePacket.Meta.Epoch, 'new-epoch');
            end
            windowResult = obj.Window.push( ...
                framePacket, obj.Config.Group);
            if ~windowResult.Available
                return;
            end

            receiveIndex = obj.Config.ReceiveAntenna;
            transmitIndex = obj.Config.TransmitAntenna;
            csi = windowResult.Data(:, :, receiveIndex, transmitIndex);
            frequencyWindow = hamming(size(csi, 1));
            timeWindow = hamming(size(csi, 2)).';
            windowedCsi = csi .* (frequencyWindow*timeWindow);
            cir = fftshift(ifft(windowedCsi, [], 1), 1);
            rdMap = fftshift(fft(cir, [], 2), 2);
            magnitudeDb = 20*log10(abs(rdMap)+1e-6);

            if ~isfinite(obj.NoiseFloorDb)
                sortedMagnitude = sort(magnitudeDb(:));
                index = max(1, round(numel(sortedMagnitude) * ...
                    obj.Config.NoiseFloorQuantile));
                obj.NoiseFloorDb = sortedMagnitude(index);
            end
            [rangeMeters, velocityMetersPerSecond] = obj.axes(size(csi));
            displayLimitsDb = [ ...
                obj.NoiseFloorDb-obj.Config.DisplayBelowNoiseDb, ...
                obj.NoiseFloorDb+obj.Config.DisplayAboveNoiseDb];
            meta = windowResult.FirstMeta;
            meta.RawEndSample0 = windowResult.LastMeta.RawEndSample0;
            meta.EndSequence = windowResult.LastMeta.EndSequence;
            meta.WindowFrames = obj.Config.WindowFrames;
            meta.HopFrames = obj.Config.HopFrames;
            obj.OutputCount = obj.OutputCount+1;
            result.Available = true;
            result.Packet = struct( ...
                'Data', struct('ComplexMap', rdMap, ...
                'MagnitudeDb', magnitudeDb, ...
                'RangeMeters', rangeMeters, ...
                'VelocityMetersPerSecond', velocityMetersPerSecond), ...
                'Meta', meta, ...
                'Quality', struct('NoiseFloorDb', obj.NoiseFloorDb, ...
                'DisplayLimitsDb', displayLimitsDb));
        end

        function reset(obj, epoch, reason)
            if nargin < 2
                epoch = NaN;
            end
            if nargin < 3
                reason = 'reset';
            end
            obj.Epoch = epoch;
            obj.NoiseFloorDb = NaN;
            obj.Window.reset(epoch, reason);
        end

        function status = getStatus(obj)
            status = struct('State', 'ready', 'Ready', true, ...
                'Epoch', obj.Epoch, 'OutputCount', obj.OutputCount, ...
                'BufferedFrames', obj.Window.Count, ...
                'NoiseFloorDb', obj.NoiseFloorDb);
        end
    end

    methods (Access = private)
        function [rangeMeters, velocity] = axes(obj, csiSize)
            speedOfLight = 299792458;
            nfft = double(obj.Context.OfdmInfo.Nfft);
            sampleRate = double(obj.Context.LteSampleRateHz);
            crsCount = csiSize(1);
            slowTimeCount = csiSize(2);
            rangeResolution = speedOfLight / ...
                ((sampleRate/nfft)*6) / 2 / crsCount;
            rangeMeters = (-crsCount/2:crsCount/2-1)*rangeResolution;
            velocityResolution = speedOfLight / ...
                obj.Context.CenterFrequencyHz * ...
                (1/5e-4/slowTimeCount)/2;
            velocity = (slowTimeCount/2:-1:-slowTimeCount/2+1) * ...
                velocityResolution;
        end

        function result = emptyResult(obj) %#ok<MANU>
            result = struct('Available', false, 'Packet', struct());
        end
    end
end
