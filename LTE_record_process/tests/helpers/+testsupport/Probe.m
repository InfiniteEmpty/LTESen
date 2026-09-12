classdef Probe < ltepipe.Module
%PROBE Record messages, resets, artifacts, and finalization in tests.

    properties (SetAccess = private)
        ProcessCount = 0
        PacketCount = 0
        ArtifactCount = 0
        ResetCount = 0
        FinalizeCount = 0
        LastReset = struct()
    end

    methods
        function obj = Probe(name, packetType)
            obj@ltepipe.Module(name, packetType, packetType);
        end

        function result = process(obj, message)
            obj.validateInput(message);
            obj.ProcessCount = obj.ProcessCount+1;
            obj.PacketCount = obj.PacketCount+double(message.HasPacket);
            obj.ArtifactCount = obj.ArtifactCount+numel(message.Artifacts);
            result = ltepipe.Result.forward(message);
        end

        function reset(obj, event)
            obj.ResetCount = obj.ResetCount+1;
            obj.LastReset = event;
        end

        function result = finalize(obj, reason) %#ok<INUSD>
            obj.FinalizeCount = obj.FinalizeCount+1;
            result = ltepipe.Result.forward(ltepipe.Message.none());
        end

        function status = getStatus(obj)
            status = struct('State', 'ready', 'Ready', true, ...
                'ProcessCount', obj.ProcessCount, ...
                'PacketCount', obj.PacketCount, ...
                'ArtifactCount', obj.ArtifactCount, ...
                'ResetCount', obj.ResetCount, ...
                'FinalizeCount', obj.FinalizeCount);
        end
    end
end
