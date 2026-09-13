classdef (Abstract) ViewerBase < ltepipe.Module
%VIEWERBASE Common lifecycle for viewers with named axes groups.

    properties (SetAccess = protected)
        Config
        UpdateCount = 0
    end

    properties (SetAccess = private)
        Axes
        AxesNames
    end

    properties (Access = private)
        FigureHandles = gobjects(0)
    end

    methods
        function obj = ViewerBase(name, inputType, outputType, ...
                config, axesGroup)
            obj@ltepipe.Module(name, inputType, outputType);
            if ~isstruct(config) || ~isscalar(config) || ...
                    ~isfield(config, 'Enabled')
                error('ltevisual:ViewerBase:InvalidConfig', ...
                    'Viewer configuration must contain Enabled.');
            end
            obj.Config = config;
            obj.AxesNames = obj.validateAxesGroup( ...
                axesGroup, config.Enabled);
            obj.Axes = axesGroup;
            obj.FigureHandles = obj.collectFigures(axesGroup);
        end
    end

    methods (Sealed)
        function result = process(obj, message)
            obj.validateInput(message);
            if obj.viewWasClosed()
                result = ltepipe.Result.stop(message, 'user-stopped');
                return;
            end
            if obj.Config.Enabled
                updates = obj.updateView(message);
                validateattributes(updates, {'numeric', 'logical'}, ...
                    {'scalar', 'integer', 'nonnegative', 'finite'});
                obj.UpdateCount = obj.UpdateCount+double(updates);
            end
            result = ltepipe.Result.forward(message);
        end

        function status = getStatus(obj)
            if ~obj.Config.Enabled
                state = 'disabled';
            elseif obj.viewWasClosed()
                state = 'closed';
            else
                state = 'ready';
            end
            status = struct('State', state, 'Ready', true, ...
                'UpdateCount', obj.UpdateCount, ...
                'AxesAvailable', obj.axesAvailability(), ...
                'FigureCount', numel(obj.FigureHandles), ...
                'FiguresAvailable', ...
                all(isgraphics(obj.FigureHandles, 'figure')));
        end
    end

    methods (Access = protected)
        function axesHandle = getAxes(obj, name)
            name = char(string(name));
            if ~isfield(obj.Axes, name)
                error('ltevisual:ViewerBase:UnknownAxes', ...
                    'Viewer "%s" has no axes named "%s".', ...
                    obj.Name, name);
            end
            axesHandle = obj.Axes.(name);
        end
    end

    methods (Access = private)
        function value = viewWasClosed(obj)
            if ~obj.Config.Enabled
                value = false;
                return;
            end
            availability = struct2cell(obj.axesAvailability());
            value = ~all([availability{:}]);
        end

        function availability = axesAvailability(obj)
            availability = struct();
            for index = 1:numel(obj.AxesNames)
                name = obj.AxesNames{index};
                axesHandle = obj.Axes.(name);
                availability.(name) = ...
                    ~isempty(axesHandle) && ...
                    isgraphics(axesHandle, 'axes');
            end
        end
    end

    methods (Static, Access = private)
        function axesNames = validateAxesGroup(axesGroup, enabled)
            if ~isstruct(axesGroup) || ~isscalar(axesGroup)
                error('ltevisual:ViewerBase:InvalidAxesGroup', ...
                    'Viewer axes must be provided as a scalar struct.');
            end
            axesNames = fieldnames(axesGroup).';
            if isempty(axesNames)
                error('ltevisual:ViewerBase:EmptyAxesGroup', ...
                    'Viewer axes must contain at least one named axes.');
            end
            for index = 1:numel(axesNames)
                axesHandle = axesGroup.(axesNames{index});
                valid = isempty(axesHandle) || ...
                    (isscalar(axesHandle) && ...
                    isgraphics(axesHandle, 'axes'));
                if ~valid
                    error('ltevisual:ViewerBase:InvalidAxes', ...
                        'Axes "%s" must be empty or a valid scalar axes.', ...
                        axesNames{index});
                end
                if enabled && isempty(axesHandle)
                    error('ltevisual:ViewerBase:MissingEnabledAxes', ...
                        'Enabled viewer axes "%s" cannot be empty.', ...
                        axesNames{index});
                end
            end
        end

        function figures = collectFigures(axesGroup)
            figures = gobjects(0);
            axesNames = fieldnames(axesGroup);
            for index = 1:numel(axesNames)
                axesHandle = axesGroup.(axesNames{index});
                if isempty(axesHandle)
                    continue;
                end
                figureHandle = ancestor(axesHandle, 'figure');
                if isempty(figures) || ~any(figures == figureHandle)
                    figures(end+1) = figureHandle; %#ok<AGROW>
                end
            end
        end
    end

    methods (Abstract, Access = protected)
        updates = updateView(obj, message)
    end
end
