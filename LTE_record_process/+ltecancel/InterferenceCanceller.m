classdef (Abstract) InterferenceCanceller < ltepipe.Module
%INTERFERENCECANCELLER Interface for frame-rate cancellation algorithms.

    methods
        function obj = InterferenceCanceller(name)
            obj@ltepipe.Module(name, 'csi-frame', 'csi-frame');
        end
    end
end
