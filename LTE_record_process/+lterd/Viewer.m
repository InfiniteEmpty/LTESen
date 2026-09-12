classdef Viewer < ltepipe.Module
%VIEWER Render range-Doppler packets without changing the message.

    properties (SetAccess = private)
        Config
        UpdateCount = 0
        AxesHandle = []
        AxesWasCreated = false
    end

    properties (Access = private)
        ImageHandle = []
        TitleHandle = []
        ColorbarHandle = []
    end

    methods
        function obj = Viewer(config, axesHandle)
            obj@ltepipe.Module( ...
                'rangeDopplerViewer', ...
                'range-doppler', 'range-doppler');
            obj.Config = config;
            obj.AxesHandle = axesHandle;
            obj.AxesWasCreated = ...
                ~isempty(axesHandle) && isgraphics(axesHandle);
        end

        function result = process(obj, message)
            obj.validateInput(message);
            if obj.Config.Enabled && message.HasPacket
                obj.render(message.Packet);
            end
            if obj.viewWasClosed()
                result = ltepipe.Result.stop(message, 'user-stopped');
            else
                result = ltepipe.Result.forward(message);
            end
        end

        function status = getStatus(obj)
            status = struct('State', 'ready', 'Ready', true, ...
                'UpdateCount', obj.UpdateCount, ...
                'AxesAvailable', ~isempty(obj.AxesHandle) && ...
                isgraphics(obj.AxesHandle), ...
                'AxesWasCreated', obj.AxesWasCreated);
        end
    end

    methods (Access = private)
        function render(obj, packet)
            if isempty(obj.AxesHandle) || ~isgraphics(obj.AxesHandle)
                return;
            end
            if isempty(obj.ImageHandle) || ...
                    ~isgraphics(obj.ImageHandle)
                obj.initializeGraphics(obj.AxesHandle, packet);
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

        function value = viewWasClosed(obj)
            value = obj.Config.Enabled && obj.AxesWasCreated && ...
                ~isgraphics(obj.AxesHandle);
        end
    end
end
