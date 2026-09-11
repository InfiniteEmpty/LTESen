classdef SyncSupervisor < handle
%SYNCSUPERVISOR Track synchronization health and request reacquisition.
%   The initial implementation consumes normalized CP-correlation quality.
%   A known-PSS observation can be added without changing the receiver API.

    properties (SetAccess = private)
        Config
        State = 'locked'
        ConsecutiveFailureCount = 0
        LastQuality = NaN
    end

    methods
        function obj = SyncSupervisor(config)
            obj.Config = config;
        end

        function event = observe(obj, quality, meta)
            obj.LastQuality = double(quality);
            event = struct('Available', false, 'Type', '', ...
                'Epoch', meta.Epoch, 'Payload', struct());
            if ~obj.Config.EnableMonitoring || ~isfinite(quality)
                return;
            end
            if quality < obj.Config.LostThreshold
                obj.ConsecutiveFailureCount = obj.ConsecutiveFailureCount + 1;
            elseif quality < obj.Config.SuspectThreshold
                obj.State = 'suspect';
                obj.ConsecutiveFailureCount = max( ...
                    1, obj.ConsecutiveFailureCount);
            else
                obj.State = 'locked';
                obj.ConsecutiveFailureCount = 0;
            end
            if obj.ConsecutiveFailureCount >= obj.Config.ConsecutiveFailures
                obj.State = 'lost';
                event.Available = true;
                event.Type = 'ResyncRequested';
                event.Payload.ExpectedRawSample0 = meta.RawEndSample0;
                event.Payload.Reason = 'tracking-quality';
            end
        end

        function reset(obj)
            obj.State = 'locked';
            obj.ConsecutiveFailureCount = 0;
            obj.LastQuality = NaN;
        end

        function status = getStatus(obj)
            status = struct('State', obj.State, ...
                'Ready', strcmp(obj.State, 'locked'), ...
                'ConsecutiveFailureCount', obj.ConsecutiveFailureCount, ...
                'LastQuality', obj.LastQuality);
        end
    end
end
