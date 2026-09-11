classdef (Abstract) InterferenceCanceller < handle
%INTERFERENCECANCELLER Interface for frame-rate cancellation algorithms.

    methods (Abstract)
        result = push(obj, framePacket)
        reset(obj, epoch, reason)
        status = getStatus(obj)
    end
end
