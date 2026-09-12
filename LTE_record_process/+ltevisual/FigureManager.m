classdef FigureManager < handle
%FIGUREMANAGER Own and reuse pipeline figures, layouts, and axes.

    properties (SetAccess = private)
        Config
    end

    properties (Access = private)
        Figures
        Layouts
        LayoutSizes
        Axes
        AxesTiles
    end

    methods
        function obj = FigureManager(config)
            obj.Config = config;
            obj.Figures = containers.Map( ...
                'KeyType', 'char', 'ValueType', 'any');
            obj.Layouts = containers.Map( ...
                'KeyType', 'char', 'ValueType', 'any');
            obj.LayoutSizes = containers.Map( ...
                'KeyType', 'char', 'ValueType', 'any');
            obj.Axes = containers.Map( ...
                'KeyType', 'char', 'ValueType', 'any');
            obj.AxesTiles = containers.Map( ...
                'KeyType', 'char', 'ValueType', 'double');
        end

        function figureHandle = getOrCreate(obj, key, name)
            key = obj.normalizeKey(key);
            if ~obj.Config.Enabled
                figureHandle = gobjects(0);
                return;
            end
            if isKey(obj.Figures, key)
                figureHandle = obj.Figures(key);
                if ~isgraphics(figureHandle)
                    % A known but invalid handle means that the user closed
                    % this figure. Do not silently reopen it.
                    figureHandle = gobjects(0);
                end
                return;
            end
            figureHandle = figure('Name', char(name), ...
                'NumberTitle', 'off', ...
                'Visible', obj.Config.FigureVisible);
            obj.Figures(key) = figureHandle;
        end

        function axesHandle = getOrCreateAxes(obj, windowKey, windowName, ...
                axesKey, gridSize, tile)
            windowKey = obj.normalizeKey(windowKey);
            axesKey = obj.normalizeKey(axesKey);
            gridSize = obj.validateGridSize(gridSize);
            tile = obj.validateTile(tile, gridSize);
            figureHandle = obj.getOrCreate(windowKey, windowName);
            if isempty(figureHandle)
                axesHandle = gobjects(0);
                return;
            end

            qualifiedAxesKey = obj.axesMapKey(windowKey, axesKey);
            if isKey(obj.Axes, qualifiedAxesKey)
                axesHandle = obj.Axes(qualifiedAxesKey);
                if isgraphics(axesHandle)
                    return;
                end
            end

            layoutHandle = obj.getOrCreateLayout( ...
                windowKey, figureHandle, gridSize);
            obj.assertTileAvailable(windowKey, qualifiedAxesKey, tile);
            axesHandle = nexttile(layoutHandle, tile);
            axesHandle.Tag = axesKey;
            obj.Axes(qualifiedAxesKey) = axesHandle;
            obj.AxesTiles(qualifiedAxesKey) = tile;
        end

        function value = isOpen(obj, key)
            key = obj.normalizeKey(key);
            value = isKey(obj.Figures, key) && ...
                isgraphics(obj.Figures(key));
        end

        function value = wasClosed(obj, key)
            key = obj.normalizeKey(key);
            value = isKey(obj.Figures, key) && ...
                ~isgraphics(obj.Figures(key));
        end

        function close(obj, key)
            key = obj.normalizeKey(key);
            if obj.isOpen(key)
                close(obj.Figures(key));
            end
        end

        function closeAll(obj)
            figureKeys = keys(obj.Figures);
            for index = 1:numel(figureKeys)
                figureHandle = obj.Figures(figureKeys{index});
                if isgraphics(figureHandle)
                    close(figureHandle);
                end
            end
        end

        function forget(obj, key)
            key = obj.normalizeKey(key);
            if isKey(obj.Figures, key)
                remove(obj.Figures, key);
            end
            if isKey(obj.Layouts, key)
                remove(obj.Layouts, key);
            end
            if isKey(obj.LayoutSizes, key)
                remove(obj.LayoutSizes, key);
            end
            obj.forgetAxes(key);
        end

        function status = getStatus(obj)
            figureKeys = keys(obj.Figures);
            open = false(size(figureKeys));
            for index = 1:numel(figureKeys)
                open(index) = isgraphics(obj.Figures(figureKeys{index}));
            end
            status = struct('Enabled', obj.Config.Enabled, ...
                'Keys', {figureKeys}, 'Open', open, ...
                'AxesKeys', {keys(obj.Axes)});
        end
    end

    methods (Access = private)
        function layoutHandle = getOrCreateLayout(obj, windowKey, ...
                figureHandle, gridSize)
            if isKey(obj.Layouts, windowKey)
                layoutHandle = obj.Layouts(windowKey);
                if isgraphics(layoutHandle)
                    configuredSize = obj.LayoutSizes(windowKey);
                    if ~isequal(configuredSize, gridSize)
                        error('ltevisual:FigureManager:LayoutConflict', ...
                            ['Window "%s" already uses a %dx%d layout; ' ...
                            'a %dx%d layout was requested.'], windowKey, ...
                            configuredSize(1), configuredSize(2), ...
                            gridSize(1), gridSize(2));
                    end
                    return;
                end
            end
            layoutHandle = tiledlayout(figureHandle, ...
                gridSize(1), gridSize(2), ...
                'TileSpacing', 'compact', 'Padding', 'compact');
            obj.Layouts(windowKey) = layoutHandle;
            obj.LayoutSizes(windowKey) = gridSize;
        end

        function assertTileAvailable(obj, windowKey, axesKey, tile)
            axesKeys = keys(obj.AxesTiles);
            prefix = [windowKey, '::'];
            for index = 1:numel(axesKeys)
                candidateKey = axesKeys{index};
                if startsWith(candidateKey, prefix) && ...
                        ~strcmp(candidateKey, axesKey) && ...
                        obj.AxesTiles(candidateKey) == tile && ...
                        isKey(obj.Axes, candidateKey) && ...
                        isgraphics(obj.Axes(candidateKey))
                    error('ltevisual:FigureManager:TileConflict', ...
                        'Tile %d in window "%s" is already occupied.', ...
                        tile, windowKey);
                end
            end
        end

        function forgetAxes(obj, windowKey)
            axesKeys = keys(obj.Axes);
            prefix = [windowKey, '::'];
            for index = 1:numel(axesKeys)
                axesKey = axesKeys{index};
                if startsWith(axesKey, prefix)
                    remove(obj.Axes, axesKey);
                    if isKey(obj.AxesTiles, axesKey)
                        remove(obj.AxesTiles, axesKey);
                    end
                end
            end
        end
    end

    methods (Static, Access = private)
        function key = normalizeKey(key)
            key = char(string(key));
            if isempty(key)
                error('ltevisual:FigureManager:EmptyKey', ...
                    'Figure keys must not be empty.');
            end
        end

        function gridSize = validateGridSize(gridSize)
            validateattributes(gridSize, {'numeric'}, ...
                {'vector', 'numel', 2, 'integer', 'positive'});
            gridSize = double(reshape(gridSize, 1, 2));
        end

        function tile = validateTile(tile, gridSize)
            validateattributes(tile, {'numeric'}, ...
                {'scalar', 'integer', 'positive', ...
                '<=', prod(gridSize)});
            tile = double(tile);
        end

        function key = axesMapKey(windowKey, axesKey)
            key = [windowKey, '::', axesKey];
        end
    end
end
