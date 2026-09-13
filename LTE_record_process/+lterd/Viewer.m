classdef Viewer < ltevisual.ViewerBase
%VIEWER Render range-Doppler packets without changing the message.

    properties (Access = private)
        ImageHandle = []
        TitleHandle = []
        ColorbarHandle = []
    end

    methods
        function obj = Viewer(config, axesGroup)
            obj@ltevisual.ViewerBase( ...
                'rangeDopplerViewer', ...
                'range-doppler', 'range-doppler', config, axesGroup);
            obj.getAxes('Main');
        end
    end

    methods (Access = protected)
        function updates = updateView(obj, message)
            updates = 0;
            if ~message.HasPacket
                return;
            end
            obj.render(obj.getAxes('Main'), message.Packet);
            updates = 1;
        end
    end

    methods (Access = private)
        function render(obj, axesHandle, packet)
            if isempty(obj.ImageHandle) || ...
                    ~isgraphics(obj.ImageHandle)
                obj.initializeGraphics(axesHandle, packet);
            else
                set(obj.ImageHandle, ...
                    'XData', packet.Data.VelocityMetersPerSecond, ...
                    'YData', packet.Data.RangeMeters, ...
                    'CData', packet.Data.MagnitudeDb);
                set(axesHandle, ...
                    'CLim', packet.Quality.DisplayLimitsDb);
            end
            obj.TitleHandle.String = sprintf( ...
                'Dynamic Range-Doppler Spectrum (epoch %d, sequence %d)', ...
                packet.Meta.Epoch, packet.Meta.EndSequence);
            drawnow limitrate;
        end

        function initializeGraphics(obj, axesHandle, packet)
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
