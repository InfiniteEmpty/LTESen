classdef Result
%RESULT Create and validate uniform module processing results.

    methods (Static)
        function result = forward(message)
            ltepipe.Message.validate(message);
            result = ltepipe.Result.create( ...
                message, 'continue', NaN, '');
        end

        function result = emit(packet)
            result = ltepipe.Result.forward( ...
                ltepipe.Message.fromPacket(packet));
        end

        function result = resetDownstream(message, epoch, reason)
            result = ltepipe.Result.create( ...
                message, 'reset-downstream', epoch, reason);
        end

        function result = stop(message, reason)
            result = ltepipe.Result.create( ...
                message, 'stop', NaN, reason);
        end

        function result = withCommands(result, commands)
            ltepipe.Result.validate(result);
            if ~iscell(commands)
                commands = {commands};
            end
            result.Commands = commands;
        end

        function validate(result)
            required = {'Message', 'Directive', 'Epoch', ...
                'Reason', 'Commands'};
            if ~isstruct(result) || ~isscalar(result) || ...
                    ~all(isfield(result, required)) || ...
                    ~iscell(result.Commands)
                error('ltepipe:Result:InvalidResult', ...
                    'A module returned an invalid pipeline result.');
            end
            ltepipe.Message.validate(result.Message);
            directive = char(result.Directive);
            if ~any(strcmp(directive, ...
                    {'continue', 'reset-downstream', 'stop'}))
                error('ltepipe:Result:InvalidDirective', ...
                    'Unsupported pipeline directive: %s', directive);
            end
            if strcmp(directive, 'reset-downstream') && ...
                    (~isnumeric(result.Epoch) || ~isscalar(result.Epoch))
                error('ltepipe:Result:InvalidEpoch', ...
                    'A downstream reset must contain a scalar epoch.');
            end
        end
    end

    methods (Static, Access = private)
        function result = create(message, directive, epoch, reason)
            result = struct( ...
                'Message', message, ...
                'Directive', char(directive), ...
                'Epoch', epoch, ...
                'Reason', char(reason), ...
                'Commands', {cell(1, 0)});
        end
    end
end
