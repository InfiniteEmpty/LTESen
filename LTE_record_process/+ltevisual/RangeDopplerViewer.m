classdef RangeDopplerViewer < handle
%RANGEDOPPLERVIEWER Render live range-Doppler products.

    properties (SetAccess = private)
        Config
        FigureManager
        UpdateCount = 0
        AxesHandle = []
    end

    properties (Access = private)
        ImageHandle = []
        TitleHandle = []
        ColorbarHandle = []
    end

    methods
        function obj = RangeDopplerViewer(config, figureManager)
            obj.Config = config;
            obj.FigureManager = figureManager;
        end

        function update(obj, packet)
            if ~obj.Config.Enabled
                return;
            end
            view = obj.Config.Views.RangeDoppler;
            axesHandle = obj.FigureManager.getOrCreateAxes( ...
                view.WindowKey, view.WindowName, view.AxesKey, ...
                view.GridSize, view.Tile);
            if isempty(axesHandle)
                return;
            end
            if isempty(obj.ImageHandle) || ...
                    ~isgraphics(obj.ImageHandle) || ...
                    ~isequal(obj.AxesHandle, axesHandle)
                obj.initializeGraphics(axesHandle, packet);
            else
                set(obj.ImageHandle, ...
                    'XData', packet.Data.VelocityMetersPerSecond, ...
                    'YData', packet.Data.RangeMeters, ...
                    'CData', packet.Data.MagnitudeDb);
                set(obj.AxesHandle, ...
                    'CLim', packet.Quality.DisplayLimitsDb);
            end
            obj.TitleHandle.String = sprintf( ...
                'Dynamic Range-Doppler Spectrum (epoch %d, sequence %d)', ...
                packet.Meta.Epoch, packet.Meta.EndSequence);
            drawnow limitrate;
            obj.UpdateCount = obj.UpdateCount+1;
        end

        function value = stopRequested(obj)
            view = obj.Config.Views.RangeDoppler;
            value = obj.Config.Enabled && ...
                obj.FigureManager.wasClosed(view.WindowKey);
        end
    end

    methods (Access = private)
        function initializeGraphics(obj, axesHandle, packet)
            obj.AxesHandle = axesHandle;
            obj.ImageHandle = imagesc(axesHandle, ...
                packet.Data.VelocityMetersPerSecond, ...
                packet.Data.RangeMeters, packet.Data.MagnitudeDb);
            set(axesHandle, 'YDir', 'normal', ...
                'CLim', packet.Quality.DisplayLimitsDb);
            colormap(axesHandle, obj.Config.Colormap);
            obj.ColorbarHandle = colorbar(axesHandle);
            obj.TitleHandle = title(axesHandle, '');
            xlabel(axesHandle, 'Velocity (m/s)');
            ylabel(axesHandle, 'Range (m)');
        end
    end
end
