classdef Pipeline < handle
%PIPELINE Connect uniformly registered streaming modules.

    properties (SetAccess = private)
        ExecutionConfig
        Runtime
        Modules = cell(1, 0)
        ModuleNames = cell(1, 0)
        State = 'created'
        Initialized = false
        Iterations = 0
        Finalized = false
        TerminationReason = ''
        FinalArtifacts = cell(1, 0)
        LastMessage
    end

    methods
        function obj = Pipeline(executionConfig)
            if nargin < 1 || isempty(executionConfig)
                executionConfig = struct( ...
                    'MaximumIterations', Inf, 'Verbose', false);
            end
            obj.ExecutionConfig = executionConfig;
            obj.Runtime = ltepipe.Runtime();
            obj.LastMessage = ltepipe.Message.none();
        end

        function register(obj, module)
            if obj.Initialized
                error('ltepipe:Pipeline:AlreadyInitialized', ...
                    'Modules cannot be registered after initialization.');
            end
            if ~isa(module, 'ltepipe.Module')
                error('ltepipe:Pipeline:InvalidModule', ...
                    'Registered objects must inherit from ltepipe.Module.');
            end
            if any(strcmp(obj.ModuleNames, module.Name))
                error('ltepipe:Pipeline:DuplicateModuleName', ...
                    'Module name "%s" is already registered.', module.Name);
            end
            obj.validateConnection(module);
            obj.Modules{end+1} = module;
            obj.ModuleNames{end+1} = module.Name;
        end

        function initialize(obj)
            if obj.Initialized
                return;
            end
            if isempty(obj.Modules)
                error('ltepipe:Pipeline:NoModules', ...
                    'At least one module must be registered.');
            end
            if ~isempty(obj.Modules{1}.InputType)
                error('ltepipe:Pipeline:MissingSource', ...
                    'The first registered module must be a source.');
            end
            obj.State = 'initializing';
            for index = 1:numel(obj.Modules)
                obj.Modules{index}.initialize(obj.Runtime);
            end
            obj.Initialized = true;
            obj.State = 'ready';
        end

        function result = step(obj)
            if obj.Finalized
                error('ltepipe:Pipeline:AlreadyFinalized', ...
                    'The pipeline cannot process data after finalization.');
            end
            obj.initialize();
            obj.State = 'running';
            obj.Iterations = obj.Iterations+1;
            result = obj.runModules(1, ltepipe.Message.none());
            obj.LastMessage = result.Message;
            if strcmp(result.Directive, 'stop')
                obj.State = 'stopping';
            else
                obj.State = 'ready';
            end
        end

        function summary = run(obj)
            maximum = obj.maximumIterations();
            terminationReason = 'maximum-iterations';
            try
                while obj.Iterations < maximum
                    result = obj.step();
                    if strcmp(result.Directive, 'stop')
                        terminationReason = result.Reason;
                        break;
                    end
                end
                obj.finalize(terminationReason);
            catch processingError
                obj.State = 'failed';
                try
                    obj.finalize('failed');
                catch finalizationError
                    warning('ltepipe:Pipeline:FinalizationFailed', ...
                        'Finalization after failure also failed: %s', ...
                        finalizationError.message);
                end
                rethrow(processingError);
            end
            summary = obj.getStatus();
            if obj.verbose()
                fprintf('Pipeline completed after %d iterations (%s).\n', ...
                    obj.Iterations, obj.TerminationReason);
            end
        end

        function artifacts = finalize(obj, reason)
            if nargin < 2 || isempty(reason)
                reason = 'completed';
            end
            if obj.Finalized
                artifacts = obj.FinalArtifacts;
                return;
            end
            obj.initialize();
            obj.State = 'finalizing';
            artifacts = cell(1, 0);
            for index = 1:numel(obj.Modules)
                moduleResult = obj.Modules{index}.finalize(reason);
                ltepipe.Result.validate(moduleResult);
                obj.dispatchCommands(moduleResult.Commands);
                if ltepipe.Message.hasContent(moduleResult.Message)
                    routedResult = obj.runModules( ...
                        index+1, moduleResult.Message);
                    artifacts = [artifacts, ...
                        routedResult.Message.Artifacts]; %#ok<AGROW>
                end
            end
            obj.FinalArtifacts = artifacts;
            obj.TerminationReason = char(reason);
            obj.Finalized = true;
            if strcmp(reason, 'failed')
                obj.State = 'failed';
            else
                obj.State = 'finalized';
            end
        end

        function module = getModule(obj, name)
            index = find(strcmp(obj.ModuleNames, char(name)), 1);
            if isempty(index)
                error('ltepipe:Pipeline:UnknownModule', ...
                    'Module "%s" is not registered.', char(name));
            end
            module = obj.Modules{index};
        end

        function status = getStatus(obj)
            moduleCount = numel(obj.Modules);
            moduleStatus = repmat(struct( ...
                'Name', '', 'Class', '', 'Status', struct()), ...
                1, moduleCount);
            for index = 1:moduleCount
                moduleStatus(index).Name = obj.ModuleNames{index};
                moduleStatus(index).Class = class(obj.Modules{index});
                moduleStatus(index).Status = ...
                    obj.Modules{index}.getStatus();
            end
            status = struct( ...
                'State', obj.State, ...
                'Iterations', obj.Iterations, ...
                'Initialized', obj.Initialized, ...
                'Finalized', obj.Finalized, ...
                'TerminationReason', obj.TerminationReason, ...
                'Modules', moduleStatus, ...
                'Runtime', obj.Runtime.getStatus(), ...
                'FinalArtifacts', {obj.FinalArtifacts});
        end
    end

    methods (Access = private)
        function result = runModules(obj, firstIndex, message)
            result = ltepipe.Result.forward(message);
            for index = firstIndex:numel(obj.Modules)
                result = obj.Modules{index}.process(result.Message);
                ltepipe.Result.validate(result);
                obj.dispatchCommands(result.Commands);
                switch result.Directive
                    case 'continue'
                        continue;
                    case 'reset-downstream'
                        obj.resetModulesAfter(index, result);
                        return;
                    case 'stop'
                        return;
                end
            end
        end

        function resetModulesAfter(obj, sourceIndex, result)
            event = struct( ...
                'Epoch', result.Epoch, ...
                'Reason', result.Reason, ...
                'Source', obj.ModuleNames{sourceIndex});
            for index = sourceIndex+1:numel(obj.Modules)
                obj.Modules{index}.reset(event);
            end
        end

        function dispatchCommands(obj, commands)
            for index = 1:numel(commands)
                command = commands{index};
                if ~isstruct(command) || ...
                        ~all(isfield(command, {'Target', 'Type'}))
                    error('ltepipe:Pipeline:InvalidCommand', ...
                        'Commands require Target and Type fields.');
                end
                target = obj.getModule(command.Target);
                target.handleCommand(command);
            end
        end

        function validateConnection(obj, module)
            if isempty(obj.Modules)
                return;
            end
            previous = obj.Modules{end};
            if ~isempty(previous.OutputType) && ...
                    ~isempty(module.InputType) && ...
                    ~strcmp(previous.OutputType, module.InputType)
                error('ltepipe:Pipeline:IncompatibleModules', ...
                    ['Module "%s" outputs "%s", but module "%s" ' ...
                    'expects "%s".'], previous.Name, ...
                    previous.OutputType, module.Name, module.InputType);
            end
        end

        function maximum = maximumIterations(obj)
            if isfield(obj.ExecutionConfig, 'MaximumIterations')
                maximum = obj.ExecutionConfig.MaximumIterations;
            elseif isfield(obj.ExecutionConfig, 'MaximumSubframes')
                maximum = obj.ExecutionConfig.MaximumSubframes;
            else
                maximum = Inf;
            end
            validateattributes(maximum, {'numeric'}, ...
                {'scalar', 'positive'});
        end

        function value = verbose(obj)
            value = isfield(obj.ExecutionConfig, 'Verbose') && ...
                obj.ExecutionConfig.Verbose;
        end
    end
end
