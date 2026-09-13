classdef MusicSpectrumViewer < ltevisual.ViewerBase
%MUSICSPECTRUMVIEWER Recursively estimate and render a frame-rate MUSIC PSD.

    properties (SetAccess = private)
        MusicConfig
        Epoch = NaN
        FrameCount = 0
        SampleCount = 0
        CovarianceUpdateCount = 0
        CovarianceMatrix
        FrequencyHz
        SpectrumDb
        SingularValues
        SingularValuesDb
    end

    properties (Access = private)
        VectorLength = 0
        SampleHistory
        CorrelationNumerator
        CorrelationWeight
        SpectrumLine = []
        TitleHandle = []
        SingularValueLine = []
        SignalCountLine = []
        SingularValueTitleHandle = []
    end

    methods
        function obj = MusicSpectrumViewer(musicConfig, displayConfig, ...
                axesGroup)
            obj@ltevisual.ViewerBase( ...
                'musicSpectrumViewer', 'csi-frame', 'csi-frame', ...
                displayConfig, axesGroup);
            obj.getAxes('Spectrum');
            obj.getAxes('SingularValues');
            obj.validateConfig(musicConfig);
            obj.MusicConfig = musicConfig;
            obj.initializeState();
        end

        function reset(obj, event)
            if nargin < 2 || ~isstruct(event) || ...
                    ~isfield(event, 'Epoch')
                epoch = NaN;
            else
                epoch = event.Epoch;
            end
            obj.initializeState();
            obj.Epoch = epoch;
        end
    end

    methods (Access = protected)
        function updates = updateView(obj, message)
            updates = 0;
            if ~message.HasPacket
                return;
            end
            packet = message.Packet;
            obj.validateFrame(packet);
            if ~isequal(obj.Epoch, packet.Meta.Epoch)
                obj.reset(struct('Epoch', packet.Meta.Epoch, ...
                    'Reason', 'new-epoch'));
            end
            obj.FrameCount = obj.FrameCount+1;
            if mod(obj.FrameCount, ...
                    obj.MusicConfig.SampleIntervalFrames) ~= 0
                return;
            end

            sample = obj.frameVector(packet.Data);
            obj.updateCorrelation(sample);
            if obj.SampleCount < obj.MusicConfig.CovarianceOrder
                return;
            end
            obj.updateSpectrum();
            obj.render();
            updates = 1;
        end
    end

    methods (Access = private)
        function initializeState(obj)
            order = obj.MusicConfig.CovarianceOrder;
            obj.Epoch = NaN;
            obj.FrameCount = 0;
            obj.SampleCount = 0;
            obj.CovarianceUpdateCount = 0;
            obj.VectorLength = 0;
            obj.SampleHistory = [];
            obj.CorrelationNumerator = complex(zeros(order, 1));
            obj.CorrelationWeight = zeros(order, 1);
            obj.CovarianceMatrix = complex(zeros(order));
            obj.FrequencyHz = [];
            obj.SpectrumDb = [];
            obj.SingularValues = [];
            obj.SingularValuesDb = [];
        end

        function sample = frameVector(obj, data)
            fieldName = char(obj.MusicConfig.DataField);
            if ~isfield(data, fieldName)
                error('ltecancel:MusicSpectrumViewer:MissingDataField', ...
                    'CSI frame data does not contain field "%s".', ...
                    fieldName);
            end
            frame = data.(fieldName);
            receive = obj.MusicConfig.ReceiveAntenna;
            transmit = obj.MusicConfig.TransmitAntenna;
            if receive > size(frame, 3) || transmit > size(frame, 4)
                error('ltecancel:MusicSpectrumViewer:AntennaIndex', ...
                    'Requested MUSIC antenna index is unavailable.');
            end
            sample = frame(:, :, receive, transmit);
            sample = sample(:);
            if obj.VectorLength == 0
                obj.VectorLength = numel(sample);
                historyLength = obj.MusicConfig.CovarianceOrder-1;
                obj.SampleHistory = complex(zeros( ...
                    obj.VectorLength, historyLength, 'like', sample));
            elseif numel(sample) ~= obj.VectorLength
                error('ltecancel:MusicSpectrumViewer:FrameSizeChanged', ...
                    'CSI frame dimensions changed without an epoch reset.');
            end
        end

        function updateCorrelation(obj, sample)
            order = obj.MusicConfig.CovarianceOrder;
            availableLag = min(obj.SampleCount, order-1);
            increment = complex(zeros(order, 1, 'like', sample));
            increment(1) = (sample'*sample)/obj.VectorLength;
            for lag = 1:availableLag
                increment(lag+1) = ...
                    (obj.SampleHistory(:, lag)'*sample)/obj.VectorLength;
            end

            active = 1:availableLag+1;
            forgetting = obj.MusicConfig.CorrelationForgetting;
            obj.CorrelationNumerator(active) = forgetting* ...
                obj.CorrelationNumerator(active) + increment(active);
            obj.CorrelationWeight(active) = forgetting* ...
                obj.CorrelationWeight(active) + 1;

            if order > 1
                obj.SampleHistory(:, 2:end) = ...
                    obj.SampleHistory(:, 1:end-1);
                obj.SampleHistory(:, 1) = sample;
            end
            obj.SampleCount = obj.SampleCount+1;
        end

        function updateSpectrum(obj)
            correlation = obj.CorrelationNumerator ./ ...
                max(obj.CorrelationWeight, eps);
            correlation(1) = real(correlation(1));
            covariance = toeplitz(correlation, conj(correlation));
            covariance = (covariance+covariance')/2;
            order = obj.MusicConfig.CovarianceOrder;
            loading = obj.MusicConfig.DiagonalLoading * ...
                max(real(trace(covariance))/order, eps);
            covariance = covariance + loading*eye(order, ...
                'like', covariance);
            obj.CovarianceMatrix = covariance;

            [eigenvectors, eigenvalues] = eig(covariance, 'vector');
            [singularValues, eigenOrder] = sort( ...
                max(real(eigenvalues), 0), 'descend');
            eigenvectors = eigenvectors(:, eigenOrder);
            obj.SingularValues = singularValues;
            obj.SingularValuesDb = 10*log10(max(singularValues, eps) / ...
                max(singularValues(1), eps));
            noiseSubspace = eigenvectors(:, ...
                obj.MusicConfig.SignalCount+1:end);

            frequencyLimit = min(obj.MusicConfig.FrequencyLimitHz, ...
                1/(2*obj.samplePeriodSeconds()));
            obj.FrequencyHz = linspace(-frequencyLimit, frequencyLimit, ...
                obj.MusicConfig.SpectrumGridSize);
            time = (0:order-1).'*obj.samplePeriodSeconds();
            steering = exp(1i*2*pi*time*obj.FrequencyHz);

            denominator = sum(abs(noiseSubspace'*steering).^2, 1);
            power = 1./max(real(denominator), 1e-12);
            obj.SpectrumDb = 10*log10(power/max(power));
            obj.CovarianceUpdateCount = obj.CovarianceUpdateCount+1;
        end

        function render(obj)
            singularValueAxes = obj.getAxes('SingularValues');
            spectrumAxes = obj.getAxes('Spectrum');
            singularValueIndex = 1:numel(obj.SingularValuesDb);
            if isempty(obj.SingularValueLine) || ...
                    ~isgraphics(obj.SingularValueLine)
                obj.SingularValueLine = plot( ...
                    singularValueAxes, singularValueIndex, ...
                    obj.SingularValuesDb, '-o', 'LineWidth', 1.2, ...
                    'MarkerSize', 4);
                grid(singularValueAxes, 'on');
                xlim(singularValueAxes, ...
                    [1, obj.MusicConfig.CovarianceOrder]);
                ylim(singularValueAxes, [-80, 5]);
                xlabel(singularValueAxes, 'Singular-value index');
                ylabel(singularValueAxes, ...
                    'Normalized singular value (dB)');
                obj.SignalCountLine = xline( ...
                    singularValueAxes, ...
                    obj.MusicConfig.SignalCount+0.5, '--', ...
                    sprintf('r = %d', obj.MusicConfig.SignalCount));
                obj.SingularValueTitleHandle = title( ...
                    singularValueAxes, '');
            else
                set(obj.SingularValueLine, ...
                    'XData', singularValueIndex, ...
                    'YData', obj.SingularValuesDb);
            end
            obj.SingularValueTitleHandle.String = sprintf( ...
                ['MUSIC Covariance Singular Values ' ...
                '(frame %d, snapshots %d)'], ...
                obj.FrameCount, obj.SampleCount);

            if isempty(obj.SpectrumLine) || ...
                    ~isgraphics(obj.SpectrumLine)
                obj.SpectrumLine = plot(spectrumAxes, ...
                    obj.FrequencyHz, obj.SpectrumDb, 'LineWidth', 1.2);
                grid(spectrumAxes, 'on');
                xlim(spectrumAxes, obj.FrequencyHz([1, end]));
                ylim(spectrumAxes, [-60, 5]);
                xlabel(spectrumAxes, 'CFO (Hz)');
                ylabel(spectrumAxes, 'Normalized MUSIC spectrum (dB)');
                obj.TitleHandle = title(spectrumAxes, '');
            else
                set(obj.SpectrumLine, 'XData', obj.FrequencyHz, ...
                    'YData', obj.SpectrumDb);
            end
            obj.TitleHandle.String = sprintf( ...
                'MUSIC(%d) CFO Spectrum (frame %d, snapshots %d)', ...
                obj.MusicConfig.SignalCount, ...
                obj.FrameCount, obj.SampleCount);
            drawnow limitrate;
        end

        function period = samplePeriodSeconds(obj)
            period = obj.MusicConfig.FramePeriodSeconds * ...
                obj.MusicConfig.SampleIntervalFrames;
        end
    end

    methods (Static, Access = private)
        function validateConfig(config)
            required = {'DataField', 'ReceiveAntenna', ...
                'TransmitAntenna', 'SampleIntervalFrames', ...
                'CovarianceOrder', 'SignalCount', ...
                'CorrelationForgetting', 'DiagonalLoading', ...
                'FramePeriodSeconds', 'FrequencyLimitHz', ...
                'SpectrumGridSize'};
            if ~isstruct(config) || ~isscalar(config) || ...
                    ~all(isfield(config, required))
                error('ltecancel:MusicSpectrumViewer:InvalidConfig', ...
                    'MUSIC viewer configuration is incomplete.');
            end
            validateattributes(config.ReceiveAntenna, {'numeric'}, ...
                {'scalar', 'integer', 'positive'});
            validateattributes(config.TransmitAntenna, {'numeric'}, ...
                {'scalar', 'integer', 'positive'});
            validateattributes(config.SampleIntervalFrames, {'numeric'}, ...
                {'scalar', 'integer', 'positive'});
            validateattributes(config.CovarianceOrder, {'numeric'}, ...
                {'scalar', 'integer', '>=', 2});
            validateattributes(config.SignalCount, {'numeric'}, ...
                {'scalar', 'integer', 'positive', '<', ...
                config.CovarianceOrder});
            validateattributes(config.CorrelationForgetting, {'numeric'}, ...
                {'scalar', 'real', '>', 0, '<=', 1});
            validateattributes(config.DiagonalLoading, {'numeric'}, ...
                {'scalar', 'real', 'finite', 'nonnegative'});
            validateattributes(config.FramePeriodSeconds, {'numeric'}, ...
                {'scalar', 'real', 'finite', 'positive'});
            validateattributes(config.FrequencyLimitHz, {'numeric'}, ...
                {'scalar', 'real', 'finite', 'positive'});
            validateattributes(config.SpectrumGridSize, {'numeric'}, ...
                {'scalar', 'integer', '>=', 3});
        end

        function validateFrame(packet)
            if ~isstruct(packet) || ~isfield(packet, 'Data') || ...
                    ~isfield(packet, 'Meta') || ...
                    ~isfield(packet.Meta, 'Epoch')
                error('ltecancel:MusicSpectrumViewer:InvalidFrame', ...
                    'Input is not a valid CSI frame packet.');
            end
        end
    end
end
