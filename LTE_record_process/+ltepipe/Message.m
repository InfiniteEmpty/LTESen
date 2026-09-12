classdef Message
%MESSAGE Create and validate messages passed between pipeline modules.

    methods (Static)
        function message = none()
            message = struct( ...
                'HasPacket', false, ...
                'Packet', struct(), ...
                'Artifacts', {cell(1, 0)});
        end

        function message = fromPacket(packet)
            ltepipe.Message.validatePacket(packet);
            message = ltepipe.Message.none();
            message.HasPacket = true;
            message.Packet = packet;
        end

        function message = replacePacket(message, packet)
            ltepipe.Message.validate(message);
            ltepipe.Message.validatePacket(packet);
            message.HasPacket = true;
            message.Packet = packet;
        end

        function message = clearPacket(message)
            ltepipe.Message.validate(message);
            message.HasPacket = false;
            message.Packet = struct();
        end

        function message = addArtifact(message, artifact)
            ltepipe.Message.validate(message);
            if ~isstruct(artifact) || ~isfield(artifact, 'Type')
                error('ltepipe:Message:InvalidArtifact', ...
                    'Artifacts must be structs with a Type field.');
            end
            message.Artifacts{end+1} = artifact;
        end

        function value = hasContent(message)
            ltepipe.Message.validate(message);
            value = message.HasPacket || ~isempty(message.Artifacts);
        end

        function type = packetType(message)
            ltepipe.Message.validate(message);
            if message.HasPacket
                type = char(message.Packet.Type);
            else
                type = '';
            end
        end

        function validate(message)
            required = {'HasPacket', 'Packet', 'Artifacts'};
            if ~isstruct(message) || ~isscalar(message) || ...
                    ~all(isfield(message, required)) || ...
                    ~islogical(message.HasPacket) || ...
                    ~isscalar(message.HasPacket) || ...
                    ~iscell(message.Artifacts)
                error('ltepipe:Message:InvalidMessage', ...
                    'Pipeline messages have an invalid structure.');
            end
            if message.HasPacket
                ltepipe.Message.validatePacket(message.Packet);
            end
        end
    end

    methods (Static, Access = private)
        function validatePacket(packet)
            required = {'Type', 'Data', 'Meta', 'Quality'};
            if ~isstruct(packet) || ~isscalar(packet) || ...
                    ~all(isfield(packet, required)) || ...
                    isempty(char(string(packet.Type)))
                error('ltepipe:Message:InvalidPacket', ...
                    ['Packets must contain nonempty Type, Data, Meta, ' ...
                    'and Quality fields.']);
            end
        end
    end
end
