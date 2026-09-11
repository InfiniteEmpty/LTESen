classdef Viewer < handle
%VIEWER Render range-Doppler products without owning signal processing.

    properties (SetAccess = private)
        Config
        FigureHandle = gobjects(0)
        UpdateCount = 0
    end

    methods
        function obj = Viewer(config)
            obj.Config = config;
        end

        function update(obj, packet)
            if ~obj.Config.Enabled
                return;
            end
            if isempty(obj.FigureHandle) || ~isgraphics(obj.FigureHandle)
                obj.FigureHandle = figure( ...
                    'Name', 'Real-Time R-D Spectrum', ...
                    'Visible', obj.Config.FigureVisible);
            end
            figure(obj.FigureHandle);
            imagesc(packet.Data.VelocityMetersPerSecond, ...
                packet.Data.RangeMeters, packet.Data.MagnitudeDb, ...
                packet.Quality.DisplayLimitsDb);
            set(gca, 'YDir', 'normal');
            colormap(obj.Config.Colormap);
            colorbar;
            title(sprintf('Dynamic Range-Doppler Spectrum (epoch %d, sequence %d)', ...
                packet.Meta.Epoch, packet.Meta.EndSequence));
            xlabel('Velocity (m/s)');
            ylabel('Range (m)');
            drawnow;
            obj.UpdateCount = obj.UpdateCount+1;
        end

        function value = stopRequested(obj)
            value = obj.Config.Enabled && obj.UpdateCount > 0 && ...
                ~isgraphics(obj.FigureHandle);
        end
    end
end
