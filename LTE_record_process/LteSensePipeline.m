classdef LteSensePipeline < handle
%LTESENSEPIPELINE Explicit orchestration of the modular LTE sensing flow.

    properties (SetAccess = private)
        Config
        Receiver
        FrameAssembler
        Canceller
        RangeDoppler
        FigureManager
        RangeDopplerViewer
        ArSpectrumViewer
        ProcessedSubframes = 0
        ProcessedFrames = 0
        ProducedMaps = 0
        LastRangeDoppler = struct()
        Finalized = false
        TerminationReason = ''
        FinalArtifacts = struct()
    end

    methods
        function obj = LteSensePipeline(dataFile, config)
            if nargin < 2 || isempty(config)
                config = defaultLteSenseConfig();
            end
            obj.Config = config;
            obj.Receiver = ltetracking.Receiver(dataFile, config);
            lock = obj.Receiver.start();
            context = obj.Receiver.Context;
            obj.FrameAssembler = ltebuffer.CsiFrameAssembler();
            obj.Canceller = obj.createCanceller(config.Cancellation);
            obj.RangeDoppler = lterd.Processor( ...
                config.RangeDoppler, context);
            obj.FigureManager = ltevisual.FigureManager(config.Display);
            obj.RangeDopplerViewer = ltevisual.RangeDopplerViewer( ...
                config.Display, obj.FigureManager);
            obj.ArSpectrumViewer = ltevisual.ArSpectrumViewer( ...
                config.Display, obj.FigureManager);
            if config.Execution.Verbose
                fprintf(['LTE receiver locked: NCellID=%d, NDLRB=%d, ' ...
                    'CellRefP=%d, CFO=%.3f Hz, raw start=%d.\n'], ...
                    context.Enb.NCellID, context.Enb.NDLRB, ...
                    context.Enb.CellRefP, lock.InitialCfoHz, ...
                    lock.RawFrameStartSample0);
            end
        end

        function result = step(obj)
            if obj.Finalized
                error('LteSensePipeline:AlreadyFinalized', ...
                    'The pipeline cannot process data after finalization.');
            end
            result = struct('EndOfFile', false, ...
                'Discontinuity', false, 'RangeDopplerAvailable', false, ...
                'RangeDopplerPacket', struct());
            receiverResult = obj.Receiver.step();
            if receiverResult.EndOfFile
                result.EndOfFile = true;
                return;
            end
            if receiverResult.Discontinuity
                obj.resetDownstream(receiverResult.Epoch, receiverResult.Reason);
                result.Discontinuity = true;
                return;
            end
            if ~receiverResult.Available
                return;
            end
            obj.ProcessedSubframes = obj.ProcessedSubframes+1;
            frameResult = obj.FrameAssembler.push(receiverResult.Packet);
            if ~frameResult.Available
                return;
            end
            obj.ProcessedFrames = obj.ProcessedFrames+1;
            cancelResult = obj.Canceller.push(frameResult.Packet);
            if ~cancelResult.Available
                return;
            end
            rdResult = obj.RangeDoppler.push(cancelResult.Packet);
            if ~rdResult.Available
                return;
            end
            obj.ProducedMaps = obj.ProducedMaps+1;
            obj.LastRangeDoppler = rdResult.Packet;
            obj.RangeDopplerViewer.update(rdResult.Packet);
            result.RangeDopplerAvailable = true;
            result.RangeDopplerPacket = rdResult.Packet;
        end

        function summary = run(obj)
            maximum = obj.Config.Execution.MaximumSubframes;
            terminationReason = 'maximum-subframes';
            try
                while obj.ProcessedSubframes < maximum && ...
                        obj.Receiver.hasMoreData()
                    if obj.RangeDopplerViewer.stopRequested()
                        terminationReason = 'user-stopped';
                        break;
                    end
                    result = obj.step();
                    if result.EndOfFile
                        terminationReason = 'end-of-file';
                        break;
                    end
                    if obj.RangeDopplerViewer.stopRequested()
                        terminationReason = 'user-stopped';
                        break;
                    end
                end
                if ~obj.Receiver.hasMoreData()
                    terminationReason = 'end-of-file';
                end
                obj.finalize(terminationReason);
            catch processingError
                try
                    obj.finalize('failed');
                catch finalizationError
                    warning('LteSensePipeline:FinalizationFailed', ...
                        'Finalization after failure also failed: %s', ...
                        finalizationError.message);
                end
                rethrow(processingError);
            end
            summary = obj.getStatus();
            if obj.Config.Execution.Verbose
                fprintf(['LTE sensing completed: %d subframes, %d frames, ' ...
                    '%d R-D maps.\n'], obj.ProcessedSubframes, ...
                    obj.ProcessedFrames, obj.ProducedMaps);
            end
        end

        function artifacts = finalize(obj, reason)
            if nargin < 2 || isempty(reason)
                reason = 'completed';
            end
            if obj.Finalized
                artifacts = obj.FinalArtifacts;
                return;
            end
            artifacts = struct();
            artifacts.Cancellation = obj.Canceller.finalize(reason);
            if artifacts.Cancellation.Available && ...
                    ~strcmp(reason, 'failed')
                obj.ArSpectrumViewer.update(artifacts.Cancellation);
            end
            obj.FinalArtifacts = artifacts;
            obj.TerminationReason = char(reason);
            obj.Finalized = true;
        end

        function status = getStatus(obj)
            status = struct( ...
                'ProcessedSubframes', obj.ProcessedSubframes, ...
                'ProcessedFrames', obj.ProcessedFrames, ...
                'ProducedMaps', obj.ProducedMaps, ...
                'Finalized', obj.Finalized, ...
                'TerminationReason', obj.TerminationReason, ...
                'Receiver', obj.Receiver.getStatus(), ...
                'Assembler', obj.FrameAssembler.getStatus(), ...
                'Canceller', obj.Canceller.getStatus(), ...
                'RangeDoppler', obj.RangeDoppler.getStatus(), ...
                'Figures', obj.FigureManager.getStatus());
        end
    end

    methods (Access = private)
        function canceller = createCanceller(obj, config) %#ok<INUSL>
            switch lower(char(config.Method))
                case {'none', 'passthrough'}
                    canceller = ltecancel.PassThroughCanceller();
                case {'ar-kalman', 'arkalman', 'kf'}
                    canceller = ltecancel.ArKalmanCanceller(config);
                otherwise
                    error('LteSensePipeline:UnknownCanceller', ...
                        'Unknown interference cancellation method: %s', ...
                        config.Method);
            end
        end

        function resetDownstream(obj, epoch, reason)
            obj.FrameAssembler.reset(epoch, reason);
            obj.Canceller.reset(epoch, reason);
            obj.RangeDoppler.reset(epoch, reason);
        end
    end
end
