classdef PassThroughCanceller < ltecancel.InterferenceCanceller
%PASSTHROUGHCANCELLER Preserve frames when cancellation is disabled.

    properties (SetAccess = private)
        Epoch = NaN
        FrameCount = 0
    end

    methods
        function result = push(obj, framePacket)
            if ~isequal(obj.Epoch, framePacket.Meta.Epoch)
                obj.reset(framePacket.Meta.Epoch, 'new-epoch');
            end
            packet = framePacket;
            packet.Meta.CancellationApplied = false;
            packet.Meta.CancellationReady = true;
            packet.Quality.Cancellation = struct( ...
                'Method', 'passthrough', 'Ready', true, ...
                'WarmupCount', 0, 'WarmupRequired', 0);
            obj.FrameCount = obj.FrameCount+1;
            result = struct('Available', true, 'Packet', packet, ...
                'Status', obj.getStatus());
        end

        function reset(obj, epoch, reason) %#ok<INUSD>
            if nargin < 2
                epoch = NaN;
            end
            obj.Epoch = epoch;
            obj.FrameCount = 0;
        end

        function status = getStatus(obj)
            status = struct('State', 'ready', 'Ready', true, ...
                'Epoch', obj.Epoch, 'FrameCount', obj.FrameCount, ...
                'Method', 'passthrough');
        end

        function artifact = finalize(obj, reason)
            if nargin < 2
                reason = 'completed';
            end
            artifact = struct('Available', false, ...
                'Type', '', 'Data', struct(), ...
                'Meta', struct('Epoch', obj.Epoch, ...
                'FrameCount', obj.FrameCount, ...
                'Reason', char(reason)));
        end
    end
end
