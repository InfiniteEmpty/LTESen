classdef ArSpectrumViewer < handle
%ARSPECTRUMVIEWER Render AR interference-spectrum artifacts.

    properties (SetAccess = private)
        Config
        FigureManager
        UpdateCount = 0
        AxesHandle = []
    end

    properties (Access = private)
        SpectrumLine = []
        RootMarkers = []
    end

    methods
        function obj = ArSpectrumViewer(config, figureManager)
            obj.Config = config;
            obj.FigureManager = figureManager;
        end

        function update(obj, artifact)
            if ~obj.Config.Enabled || ~artifact.Available
                return;
            end
            if ~strcmp(artifact.Type, 'ar-interference-spectrum')
                error('ltevisual:ArSpectrumViewer:ArtifactType', ...
                    'Unsupported artifact type: %s', artifact.Type);
            end
            view = obj.Config.Views.ArSpectrum;
            axesHandle = obj.FigureManager.getOrCreateAxes( ...
                view.WindowKey, view.WindowName, view.AxesKey, ...
                view.GridSize, view.Tile);
            if isempty(axesHandle)
                return;
            end
            if isempty(obj.SpectrumLine) || ...
                    ~isgraphics(obj.SpectrumLine) || ...
                    ~isequal(obj.AxesHandle, axesHandle)
                obj.initializeGraphics(axesHandle, artifact);
            else
                set(obj.SpectrumLine, ...
                    'XData', artifact.Data.FrequencyHz, ...
                    'YData', artifact.Data.SpectrumDb);
                set(obj.RootMarkers, ...
                    'XData', artifact.Data.RootHz, ...
                    'YData', zeros(size(artifact.Data.RootHz)));
                xlim(obj.AxesHandle, ...
                    artifact.Data.FrequencyHz([1, end]));
            end
            drawnow limitrate;
            obj.UpdateCount = obj.UpdateCount+1;
        end
    end

    methods (Access = private)
        function initializeGraphics(obj, axesHandle, artifact)
            obj.AxesHandle = axesHandle;
            obj.SpectrumLine = plot(axesHandle, ...
                artifact.Data.FrequencyHz, artifact.Data.SpectrumDb, ...
                'LineWidth', 1.2);
            hold(axesHandle, 'on');
            obj.RootMarkers = stem(axesHandle, artifact.Data.RootHz, ...
                zeros(size(artifact.Data.RootHz)), ...
                'r', 'filled', 'LineWidth', 1);
            hold(axesHandle, 'off');
            grid(axesHandle, 'on');
            xlim(axesHandle, artifact.Data.FrequencyHz([1, end]));
            ylim(axesHandle, [-60, 5]);
            xlabel(axesHandle, 'CFO (Hz)');
            ylabel(axesHandle, 'Normalized AR spectrum (dB)');
            title(axesHandle, 'AR Interference CFO Spectrum');
            legend(axesHandle, [obj.SpectrumLine, obj.RootMarkers], ...
                {'AR spectrum', 'AR roots'}, 'Location', 'best');
        end
    end
end
