classdef (Abstract) Module < handle
%MODULE Uniform lifecycle and data contract for pipeline modules.

    properties (SetAccess = private)
        Name
        InputType
        OutputType
    end

    properties (SetAccess = protected)
        Runtime
    end

    methods
        function obj = Module(name, inputType, outputType)
            obj.Name = obj.validateName(name);
            obj.InputType = char(inputType);
            obj.OutputType = char(outputType);
        end

        function initialize(obj, runtime)
            obj.Runtime = runtime;
        end

        function reset(obj, event) %#ok<INUSD>
        end

        function result = finalize(obj, reason) %#ok<INUSD>
            result = ltepipe.Result.forward(ltepipe.Message.none());
        end

        function status = getStatus(obj) %#ok<MANU>
            status = struct('State', 'ready', 'Ready', true);
        end

        function handleCommand(obj, command)
            if isstruct(command) && isfield(command, 'Type')
                commandType = char(command.Type);
            else
                commandType = '<invalid>';
            end
            error('ltepipe:Module:UnsupportedCommand', ...
                'Module "%s" does not support command "%s".', ...
                obj.Name, commandType);
        end
    end

    methods (Abstract)
        result = process(obj, message)
    end

    methods (Access = protected)
        function validateInput(obj, message)
            ltepipe.Message.validate(message);
            if message.HasPacket && ~isempty(obj.InputType) && ...
                    ~strcmp(message.Packet.Type, obj.InputType)
                error('ltepipe:Module:InputType', ...
                    'Module "%s" expected "%s" but received "%s".', ...
                    obj.Name, obj.InputType, message.Packet.Type);
            end
        end

        function message = replaceOutput(obj, message, packet)
            if ~isempty(obj.OutputType) && ...
                    ~strcmp(packet.Type, obj.OutputType)
                error('ltepipe:Module:OutputType', ...
                    'Module "%s" produced "%s" instead of "%s".', ...
                    obj.Name, packet.Type, obj.OutputType);
            end
            message = ltepipe.Message.replacePacket(message, packet);
        end
    end

    methods (Static, Access = private)
        function name = validateName(name)
            name = char(string(name));
            if isempty(name) || ~isvarname(name)
                error('ltepipe:Module:InvalidName', ...
                    'Module names must be valid MATLAB identifiers.');
            end
        end
    end
end
