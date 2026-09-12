classdef ScriptedSource < ltepipe.Module
%SCRIPTEDSOURCE Deterministic source used by pipeline unit tests.

    properties (SetAccess = private)
        Results
        ProcessCount = 0
    end

    methods
        function obj = ScriptedSource(results, outputType)
            obj@ltepipe.Module('source', '', outputType);
            obj.Results = results;
        end

        function result = process(obj, message) %#ok<INUSD>
            obj.ProcessCount = obj.ProcessCount+1;
            if obj.ProcessCount <= numel(obj.Results)
                result = obj.Results{obj.ProcessCount};
            else
                result = ltepipe.Result.stop( ...
                    ltepipe.Message.none(), 'end-of-script');
            end
        end

        function status = getStatus(obj)
            status = struct('State', 'ready', 'Ready', true, ...
                'ProcessCount', obj.ProcessCount);
        end
    end
end
