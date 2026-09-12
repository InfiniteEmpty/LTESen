classdef ArSpectrumViewer < ltepipe.Module
%ARSPECTRUMVIEWER Render AR spectrum artifacts and pass messages through.

    properties (SetAccess = private)
        Config
        UpdateCount = 0
        AxesHandle = []
        AxesWasCreated = false
    end

    properties (Access = private)
        SpectrumLine = []
        RootMarkers = []
    end

    methods
        function obj = ArSpectrumViewer(config, axesHandle)
            obj@ltepipe.Module( ...
                'arSpectrumViewer', 'csi-frame', 'csi-frame');
            obj.Config = config;
            obj.AxesHandle = axesHandle;
            obj.AxesWasCreated = ...
                ~isempty(axesHandle) && isgraphics(axesHandle);
        end

        function result = process(obj, message)
            obj.validateInput(message);
            if obj.Config.Enabled
                for index = 1:numel(message.Artifacts)
                    artifact = message.Artifacts{index};
                    if isstruct(artifact) && ...
                            isfield(artifact, 'Type') && ...
                            strcmp(artifact.Type, ...
                            'ar-interference-spectrum') && ...
                            ~obj.isFailureArtifact(artifact)
                        obj.render(artifact);
                    end
                end
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
        function render(obj, artifact)
            if ~isfield(artifact, 'Available') || ~artifact.Available
                return;
            end
            if isempty(obj.AxesHandle) || ~isgraphics(obj.AxesHandle)
                return;
            end
            if isempty(obj.SpectrumLine) || ...
                    ~isgraphics(obj.SpectrumLine)
                obj.initializeGraphics(obj.AxesHandle, artifact);
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

        function value = viewWasClosed(obj)
            value = obj.Config.Enabled && obj.AxesWasCreated && ...
                ~isgraphics(obj.AxesHandle);
        end

        function value = isFailureArtifact(obj, artifact) %#ok<INUSL>
            value = isfield(artifact, 'Meta') && ...
                isfield(artifact.Meta, 'Reason') && ...
                strcmp(artifact.Meta.Reason, 'failed');
        end
    end
end
