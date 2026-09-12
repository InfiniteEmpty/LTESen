classdef Receiver < handle
%RECEIVER Composite streaming LTE receiver with internal tracking feedback.

    properties (SetAccess = private)
        DataFile
        Config
        Lock
        Context
        Started = false
        EndOfFile = false
    end

    properties (Access = private)
        Acquirer
        Timebase
        CfoTracker
        CsiTracker
        SyncSupervisor
    end

    methods
        function obj = Receiver(dataFile, config)
            obj.DataFile = dataFile;
            obj.Config = config;
            obj.Acquirer = ltesync.Acquirer(config.Acquisition);
            obj.SyncSupervisor = ltesync.SyncSupervisor(config.Sync);
        end

        function lock = start(obj)
            obj.Lock = obj.Acquirer.acquire(obj.DataFile, 1);
            obj.configureFromLock();
            obj.Started = true;
            lock = obj.Lock;
        end

        function value = hasMoreData(obj)
            if ~obj.Started
                value = true;
            else
                value = obj.Timebase.canRead(obj.DataFile.sample_count);
            end
        end

        function result = step(obj)
            if ~obj.Started
                obj.start();
            end
            result = obj.emptyResult();
            if ~obj.Timebase.canRead(obj.DataFile.sample_count)
                obj.EndOfFile = true;
                result.EndOfFile = true;
                return;
            end

            meta = obj.Timebase.currentMeta();
            rawWaveform = single(obj.DataFile.readAt( ...
                meta.RawStartSample0, meta.RawSampleCount, false));
            antennaIndices = obj.Config.Tracking.ReceiveAntennaIndices;
            if any(antennaIndices > size(rawWaveform, 2))
                error('ltetracking:Receiver:ReceiveAntenna', ...
                    'A requested receive antenna is not available.');
            end
            rawWaveform = rawWaveform(:, antennaIndices);
            waveform = obj.resampleSubframe(rawWaveform);
            [waveform, cfoQuality] = obj.CfoTracker.correct(waveform);

            enb = obj.Context.Enb;
            enb.NFrame = meta.FrameNumber;
            enb.NSubframe = meta.SubframeNumber;
            [fullGrid, gridInfo] = ltetracking.lteOFDMDemodulateFull( ...
                enb, waveform, obj.Config.Tracking.CpFraction);
            expectedSymbols = numel(obj.Context.OfdmInfo.CyclicPrefixLengths);
            if isempty(fullGrid) || size(fullGrid, 2) < expectedSymbols
                error('ltetracking:Receiver:DemodulationFailed', ...
                    'OFDM demodulation did not produce a full subframe.');
            end
            activeGrid = fullGrid(gridInfo.activeIdx, 1:expectedSymbols, :);
            [g1, g2, indexG1, indexG2] = ...
                ltetracking.fastDLCSIEstimate(enb, activeGrid);
            [data, trackingQuality] = obj.CsiTracker.correct( ...
                g1, g2, indexG1, indexG2);

            meta.NCellID = enb.NCellID;
            meta.CancellationApplied = false;
            packet = struct('Data', data, 'Meta', meta, ...
                'Quality', struct('Cfo', cfoQuality, ...
                'Tracking', trackingQuality));
            syncEvent = obj.SyncSupervisor.observe( ...
                cfoQuality.CpCorrelation, meta);
            if syncEvent.Available
                result = obj.reacquire(syncEvent);
                return;
            end

            obj.Timebase.advance(trackingQuality.TimingDeltaLteSamples);
            result.Available = true;
            result.Packet = packet;
            result.Epoch = meta.Epoch;
            result.Status = obj.getStatus();
        end

        function status = getStatus(obj)
            if ~obj.Started
                status = struct('State', 'cold', 'Ready', false);
                return;
            end
            status = struct('State', 'ready', 'Ready', true, ...
                'Epoch', obj.Lock.Epoch, ...
                'Cfo', obj.CfoTracker.getStatus(), ...
                'Csi', obj.CsiTracker.getStatus(), ...
                'Sync', obj.SyncSupervisor.getStatus());
        end
    end

    methods (Access = private)
        function configureFromLock(obj)
            enb = obj.Lock.Enb;
            enb.CellRefP = min( ...
                enb.CellRefP, obj.Config.Tracking.MaximumTxPorts);
            obj.Context = struct( ...
                'Epoch', obj.Lock.Epoch, ...
                'Enb', enb, ...
                'OfdmInfo', obj.Lock.OfdmInfo, ...
                'RawSampleRateHz', obj.Lock.RawSampleRateHz, ...
                'ReportedRawSampleRateHz', ...
                obj.Lock.ReportedRawSampleRateHz, ...
                'LteSampleRateHz', obj.Lock.LteSampleRateHz, ...
                'CenterFrequencyHz', double(obj.DataFile.frequency), ...
                'ReceiveAntennaCount', ...
                numel(obj.Config.Tracking.ReceiveAntennaIndices));
            obj.Timebase = ltesync.Timebase(obj.Lock);
            obj.CfoTracker = ltetracking.CfoTracker( ...
                obj.Config.Tracking, obj.Lock);
            obj.CsiTracker = ltetracking.CsiTracker( ...
                obj.Config.Tracking, obj.Context);
            obj.SyncSupervisor.reset();
        end

        function waveform = resampleSubframe(obj, rawWaveform)
            rawRate = obj.Context.RawSampleRateHz;
            lteRate = obj.Context.LteSampleRateHz;
            targetLength = round(lteRate/1000);
            if rawRate == lteRate
                waveform = rawWaveform;
            else
                waveform = zeros(targetLength, size(rawWaveform, 2), ...
                    'like', rawWaveform);
                for antenna = 1:size(rawWaveform, 2)
                    values = resample(rawWaveform(:, antenna), lteRate, rawRate);
                    if numel(values) < targetLength
                        error('ltetracking:Receiver:ResampleLength', ...
                            'Resampling returned fewer than one LTE subframe.');
                    end
                    waveform(:, antenna) = values(1:targetLength);
                end
            end
            if size(waveform, 1) < targetLength
                error('ltetracking:Receiver:ShortRead', ...
                    'The source returned fewer than one subframe.');
            end
            waveform = waveform(1:targetLength, :);
        end

        function result = reacquire(obj, event)
            searchStart = max(0, event.Payload.ExpectedRawSample0 - ...
                round(0.005*obj.Context.RawSampleRateHz));
            previousEpoch = obj.Lock.Epoch;
            obj.Lock = obj.Acquirer.acquire( ...
                obj.DataFile, previousEpoch+1, searchStart);
            obj.configureFromLock();
            result = obj.emptyResult();
            result.Discontinuity = true;
            result.Epoch = obj.Lock.Epoch;
            result.Reason = event.Payload.Reason;
            result.Status = obj.getStatus();
        end

        function result = emptyResult(obj) %#ok<MANU>
            result = struct( ...
                'Available', false, ...
                'Packet', struct(), ...
                'Discontinuity', false, ...
                'Epoch', NaN, ...
                'Reason', '', ...
                'EndOfFile', false, ...
                'Status', struct());
        end
    end
end
