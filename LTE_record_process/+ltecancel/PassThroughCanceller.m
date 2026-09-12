classdef PassThroughCanceller < ltecancel.InterferenceCanceller
%PASSTHROUGHCANCELLER Preserve frames when cancellation is disabled.

    properties (SetAccess = private)
        Epoch = NaN
        FrameCount = 0
    end

    methods
        function obj = PassThroughCanceller()
            obj@ltecancel.InterferenceCanceller('canceller');
        end

        function result = process(obj, message)
            obj.validateInput(message);
            if ~message.HasPacket
                result = ltepipe.Result.forward(message);
                return;
            end
            framePacket = message.Packet;
            if ~isequal(obj.Epoch, framePacket.Meta.Epoch)
                obj.reset(struct('Epoch', framePacket.Meta.Epoch, ...
                    'Reason', 'new-epoch'));
            end
            packet = framePacket;
            packet.Meta.CancellationApplied = false;
            packet.Meta.CancellationReady = true;
            packet.Quality.Cancellation = struct( ...
                'Method', 'passthrough', 'Ready', true, ...
                'WarmupCount', 0, 'WarmupRequired', 0);
            obj.FrameCount = obj.FrameCount+1;
            result = ltepipe.Result.forward( ...
                obj.replaceOutput(message, packet));
        end

        function reset(obj, event)
            if nargin < 2 || ~isstruct(event) || ...
                    ~isfield(event, 'Epoch')
                epoch = NaN;
            else
                epoch = event.Epoch;
            end
            obj.Epoch = epoch;
            obj.FrameCount = 0;
        end

        function status = getStatus(obj)
            status = struct('State', 'ready', 'Ready', true, ...
                'Epoch', obj.Epoch, 'FrameCount', obj.FrameCount, ...
                'Method', 'passthrough');
        end

        function result = finalize(obj, reason) %#ok<INUSD>
            result = ltepipe.Result.forward(ltepipe.Message.none());
        end
    end
end
