classdef FinalizeEmitter < ltepipe.Module
%FINALIZEEMITTER Emit one artifact during finalization for tests.

    properties (SetAccess = private)
        Finalized = false
        FinalResult
    end

    methods
        function obj = FinalizeEmitter()
            obj@ltepipe.Module('finalizeEmitter', 'test', 'test');
            obj.FinalResult = ltepipe.Result.forward( ...
                ltepipe.Message.none());
        end

        function result = process(obj, message)
            obj.validateInput(message);
            result = ltepipe.Result.forward(message);
        end

        function result = finalize(obj, reason)
            if ~obj.Finalized
                artifact = struct('Available', true, ...
                    'Type', 'test-artifact', ...
                    'Data', struct('Value', 7), ...
                    'Meta', struct('Reason', char(reason)));
                message = ltepipe.Message.addArtifact( ...
                    ltepipe.Message.none(), artifact);
                obj.FinalResult = ltepipe.Result.forward(message);
                obj.Finalized = true;
            end
            result = obj.FinalResult;
        end
    end
end
