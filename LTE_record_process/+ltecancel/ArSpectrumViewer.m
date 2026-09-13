classdef ArSpectrumViewer < ltevisual.ViewerBase
%ARSPECTRUMVIEWER Render AR spectrum artifacts and pass messages through.

    properties (Access = private)
        SpectrumLine = []
        RootMarkers = []
    end

    methods
        function obj = ArSpectrumViewer(config, axesGroup)
            obj@ltevisual.ViewerBase( ...
                'arSpectrumViewer', 'csi-frame', 'csi-frame', ...
                config, axesGroup);
            obj.getAxes('Spectrum');
        end
    end

    methods (Access = protected)
        function updates = updateView(obj, message)
            updates = 0;
            for index = 1:numel(message.Artifacts)
                artifact = message.Artifacts{index};
                if isstruct(artifact) && ...
                        isfield(artifact, 'Type') && ...
                        strcmp(artifact.Type, ...
                        'ar-interference-spectrum') && ...
                        ~obj.isFailureArtifact(artifact) && ...
                        obj.render(obj.getAxes('Spectrum'), artifact)
                    updates = updates+1;
                end
            end
        end
    end

    methods (Access = private)
        function rendered = render(obj, axesHandle, artifact)
            rendered = false;
            if ~isfield(artifact, 'Available') || ~artifact.Available
                return;
            end
            [frequencyCoordinate, rootCoordinate, tickCoordinate, ...
                tickLabels, frequencyLabel] = obj.axisData(artifact);
            if isempty(obj.SpectrumLine) || ...
                    ~isgraphics(obj.SpectrumLine)
                obj.initializeGraphics(axesHandle, artifact, ...
                    frequencyCoordinate, rootCoordinate);
            else
                set(obj.SpectrumLine, ...
                    'XData', frequencyCoordinate, ...
                    'YData', artifact.Data.SpectrumDb);
                set(obj.RootMarkers, ...
                    'XData', rootCoordinate, ...
                    'YData', zeros(size(artifact.Data.RootHz)));
                xlim(axesHandle, ...
                    frequencyCoordinate([1, end]));
            end
            xticks(axesHandle, tickCoordinate);
            xticklabels(axesHandle, tickLabels);
            xlabel(axesHandle, frequencyLabel);
            drawnow limitrate;
            rendered = true;
        end

        function initializeGraphics(obj, axesHandle, artifact, ...
                frequencyCoordinate, rootCoordinate)
            obj.SpectrumLine = plot(axesHandle, ...
                frequencyCoordinate, artifact.Data.SpectrumDb, ...
                'LineWidth', 1.2);
            hold(axesHandle, 'on');
            obj.RootMarkers = stem(axesHandle, rootCoordinate, ...
                zeros(size(artifact.Data.RootHz)), ...
                'r', 'filled', 'LineWidth', 1);
            hold(axesHandle, 'off');
            grid(axesHandle, 'on');
            xlim(axesHandle, frequencyCoordinate([1, end]));
            ylim(axesHandle, [-60, 5]);
            ylabel(axesHandle, 'Normalized AR spectrum (dB)');
            title(axesHandle, 'AR Interference CFO Spectrum');
            legend(axesHandle, [obj.SpectrumLine, obj.RootMarkers], ...
                {'AR spectrum', 'AR roots'}, 'Location', 'best');
        end

        function [frequencyCoordinate, rootCoordinate, tickCoordinate, ...
                tickLabels, frequencyLabel] = axisData(obj, artifact) %#ok<INUSL>
            frequencyHz = artifact.Data.FrequencyHz;
            rootHz = artifact.Data.RootHz;
            useAsinh = isfield(artifact.Data, 'FrequencyAxis') && ...
                strcmpi(char(artifact.Data.FrequencyAxis), 'asinh') && ...
                isfield(artifact.Data, 'FrequencyLinearScaleHz') && ...
                isfinite(artifact.Data.FrequencyLinearScaleHz) && ...
                artifact.Data.FrequencyLinearScaleHz > 0;
            if ~useAsinh
                frequencyCoordinate = frequencyHz;
                rootCoordinate = rootHz;
                tickCoordinate = linspace(frequencyHz(1), ...
                    frequencyHz(end), 5);
                tickLabels = compose('%g', tickCoordinate);
                frequencyLabel = 'CFO (Hz)';
                return;
            end

            linearScaleHz = artifact.Data.FrequencyLinearScaleHz;
            frequencyCoordinate = asinh(frequencyHz/linearScaleHz);
            rootCoordinate = asinh(rootHz/linearScaleHz);
            maximumFrequencyHz = max(abs(frequencyHz));
            maximumDecade = max(0, floor(log10( ...
                maximumFrequencyHz/linearScaleHz)));
            positiveTicksHz = linearScaleHz*10.^(0:maximumDecade);
            positiveTicksHz = positiveTicksHz( ...
                positiveTicksHz < maximumFrequencyHz);
            positiveTicksHz = [positiveTicksHz, maximumFrequencyHz];
            tickHz = [-fliplr(positiveTicksHz), 0, positiveTicksHz];
            tickCoordinate = asinh(tickHz/linearScaleHz);
            tickLabels = compose('%g', tickHz);
            frequencyLabel = 'CFO (Hz, asinh scale)';
        end

        function value = isFailureArtifact(obj, artifact) %#ok<INUSL>
            value = isfield(artifact, 'Meta') && ...
                isfield(artifact.Meta, 'Reason') && ...
                strcmp(artifact.Meta.Reason, 'failed');
        end
    end
end
