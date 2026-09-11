classdef FrameWindow < handle
%FRAMEWINDOW Fixed-size frame ring with configurable output hop.

    properties (SetAccess = private)
        WindowFrames
        HopFrames
        Epoch = NaN
        Count = 0
        FramesSinceOutput = 0
    end

    properties (Access = private)
        Buffer
        Metadata
        WriteIndex = 0
        LastEndSequence = NaN
    end

    methods
        function obj = FrameWindow(windowFrames, hopFrames)
            validateattributes(windowFrames, {'numeric'}, ...
                {'scalar', 'integer', 'positive'});
            validateattributes(hopFrames, {'numeric'}, ...
                {'scalar', 'integer', 'positive'});
            obj.WindowFrames = double(windowFrames);
            obj.HopFrames = double(hopFrames);
        end

        function result = push(obj, framePacket, fieldName)
            if nargin < 3
                fieldName = 'G1';
            end
            obj.validateFrame(framePacket, fieldName);
            meta = framePacket.Meta;
            if ~isequal(obj.Epoch, meta.Epoch)
                obj.reset(meta.Epoch, 'new-epoch');
            end
            if obj.Count > 0 && meta.Sequence ~= obj.LastEndSequence + 1
                obj.reset(meta.Epoch, 'sequence-gap');
            end
            frame = framePacket.Data.(fieldName);
            if isempty(obj.Buffer)
                bufferSize = [size(frame, 1), size(frame, 2), ...
                    size(frame, 3), size(frame, 4), obj.WindowFrames];
                obj.Buffer = complex(zeros(bufferSize, 'like', frame));
                obj.Metadata = cell(1, obj.WindowFrames);
            end
            obj.WriteIndex = mod(obj.WriteIndex, obj.WindowFrames)+1;
            obj.Buffer(:, :, :, :, obj.WriteIndex) = frame;
            obj.Metadata{obj.WriteIndex} = meta;
            obj.Count = min(obj.Count+1, obj.WindowFrames);
            obj.FramesSinceOutput = obj.FramesSinceOutput+1;
            obj.LastEndSequence = meta.EndSequence;

            result = struct('Available', false, 'Data', [], ...
                'FirstMeta', struct(), 'LastMeta', struct());
            if obj.Count < obj.WindowFrames || ...
                    obj.FramesSinceOutput < obj.HopFrames
                return;
            end
            indices = mod((obj.WriteIndex-obj.WindowFrames+1:obj.WriteIndex)-1, ...
                obj.WindowFrames)+1;
            ordered = obj.Buffer(:, :, :, :, indices);
            ordered = permute(ordered, [1, 2, 5, 3, 4]);
            outputSize = [size(frame, 1), ...
                size(frame, 2)*obj.WindowFrames, ...
                size(frame, 3), size(frame, 4)];
            result.Data = reshape(ordered, outputSize);
            result.FirstMeta = obj.Metadata{indices(1)};
            result.LastMeta = obj.Metadata{indices(end)};
            result.Available = true;
            obj.FramesSinceOutput = 0;
        end

        function reset(obj, epoch, reason) %#ok<INUSD>
            if nargin < 2
                epoch = NaN;
            end
            obj.Epoch = epoch;
            obj.Count = 0;
            obj.FramesSinceOutput = 0;
            obj.Buffer = [];
            obj.Metadata = {};
            obj.WriteIndex = 0;
            obj.LastEndSequence = NaN;
        end
    end

    methods (Static, Access = private)
        function validateFrame(packet, fieldName)
            if ~isstruct(packet) || ~isfield(packet, 'Data') || ...
                    ~isfield(packet.Data, fieldName) || ...
                    ~isfield(packet, 'Meta') || ...
                    ~all(isfield(packet.Meta, ...
                    {'Epoch', 'Sequence', 'EndSequence'}))
                error('ltebuffer:FrameWindow:InvalidFrame', ...
                    'Input is not a valid CSI frame packet.');
            end
        end
    end
end
