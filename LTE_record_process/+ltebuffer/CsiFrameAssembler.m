classdef CsiFrameAssembler < handle
%CSIFRAMEASSEMBLER Assemble ten consecutive CSI subframes into one frame.

    properties (SetAccess = private)
        Epoch = NaN
        BufferedSubframes = 0
        EmittedFrames = 0
        DroppedPartialFrames = 0
    end

    properties (Access = private)
        Buffer
        FirstMeta
        ExpectedSequence = NaN
    end

    methods
        function result = push(obj, packet)
            obj.validatePacket(packet);
            meta = packet.Meta;
            if ~isequal(obj.Epoch, meta.Epoch)
                obj.reset(meta.Epoch, 'new-epoch');
            end
            if obj.BufferedSubframes > 0 && ...
                    meta.Sequence ~= obj.ExpectedSequence
                obj.discardPartial();
            end
            if obj.BufferedSubframes > 0 && ...
                    meta.SubframeNumber ~= obj.BufferedSubframes
                obj.discardPartial();
            end
            if obj.BufferedSubframes == 0
                if meta.SubframeNumber ~= 0
                    result = obj.emptyResult();
                    return;
                end
                obj.allocate(packet.Data);
                obj.FirstMeta = meta;
            end

            columns = meta.SubframeNumber*2 + (1:2);
            obj.Buffer.G1(:, columns, :, :) = packet.Data.G1;
            obj.Buffer.G2(:, columns, :, :) = packet.Data.G2;
            obj.Buffer.DynamicG1(:, columns, :, :) = packet.Data.DynamicG1;
            obj.Buffer.DynamicG2(:, columns, :, :) = packet.Data.DynamicG2;
            obj.BufferedSubframes = obj.BufferedSubframes + 1;
            obj.ExpectedSequence = meta.Sequence + 1;

            result = obj.emptyResult();
            if meta.SubframeNumber ~= 9
                return;
            end
            frameMeta = obj.FirstMeta;
            frameMeta.RawEndSample0 = meta.RawEndSample0;
            frameMeta.EndSequence = meta.Sequence;
            frameMeta.SubframeNumber = [];
            result.Available = true;
            result.Packet = struct('Data', obj.Buffer, ...
                'Meta', frameMeta, ...
                'Quality', struct('Complete', true, ...
                'SubframeCount', obj.BufferedSubframes));
            obj.EmittedFrames = obj.EmittedFrames + 1;
            obj.clearPartial();
        end

        function reset(obj, epoch, reason) %#ok<INUSD>
            if nargin < 2
                epoch = NaN;
            end
            if obj.BufferedSubframes > 0
                obj.DroppedPartialFrames = obj.DroppedPartialFrames + 1;
            end
            obj.Epoch = epoch;
            obj.Buffer = struct();
            obj.FirstMeta = struct();
            obj.BufferedSubframes = 0;
            obj.ExpectedSequence = NaN;
        end

        function status = getStatus(obj)
            status = struct('State', 'ready', 'Ready', true, ...
                'Epoch', obj.Epoch, ...
                'BufferedSubframes', obj.BufferedSubframes, ...
                'EmittedFrames', obj.EmittedFrames, ...
                'DroppedPartialFrames', obj.DroppedPartialFrames);
        end
    end

    methods (Access = private)
        function allocate(obj, data)
            obj.Buffer = struct( ...
                'G1', complex(zeros(size(data.G1, 1), 20, ...
                size(data.G1, 3), size(data.G1, 4), 'like', data.G1)), ...
                'G2', complex(zeros(size(data.G2, 1), 20, ...
                size(data.G2, 3), size(data.G2, 4), 'like', data.G2)), ...
                'DynamicG1', complex(zeros(size(data.DynamicG1, 1), 20, ...
                size(data.DynamicG1, 3), size(data.DynamicG1, 4), ...
                'like', data.DynamicG1)), ...
                'DynamicG2', complex(zeros(size(data.DynamicG2, 1), 20, ...
                size(data.DynamicG2, 3), size(data.DynamicG2, 4), ...
                'like', data.DynamicG2)));
        end

        function discardPartial(obj)
            if obj.BufferedSubframes > 0
                obj.DroppedPartialFrames = obj.DroppedPartialFrames + 1;
            end
            obj.clearPartial();
        end

        function clearPartial(obj)
            obj.Buffer = struct();
            obj.FirstMeta = struct();
            obj.BufferedSubframes = 0;
            obj.ExpectedSequence = NaN;
        end

        function validatePacket(~, packet)
            required = {'G1', 'G2', 'DynamicG1', 'DynamicG2'};
            if ~isstruct(packet) || ~isfield(packet, 'Data') || ...
                    ~isfield(packet, 'Meta') || ...
                    ~all(isfield(packet.Data, required))
                error('ltebuffer:CsiFrameAssembler:InvalidPacket', ...
                    'Input is not a valid CSI subframe packet.');
            end
            metaFields = {'Epoch', 'Sequence', 'SubframeNumber'};
            if ~all(isfield(packet.Meta, metaFields))
                error('ltebuffer:CsiFrameAssembler:InvalidMetadata', ...
                    'CSI subframe metadata is incomplete.');
            end
        end

        function result = emptyResult(obj) %#ok<MANU>
            result = struct('Available', false, 'Packet', struct());
        end
    end
end
