classdef ArKalmanCanceller < ltecancel.InterferenceCanceller
%ARKALMANCANCELLER Frame-rate recursive AR/Kalman interference canceller.

    properties (SetAccess = private)
        Config
        Epoch = NaN
        FrameCount = 0
        Ready = false
        LastCancellationGain = 0
        SmoothedCoherence = 0
        RootHz
        YuleWalkerRcond = NaN
        Finalized = false
    end

    properties (Access = private)
        VectorLength = 0
        G1ElementCount = 0
        G1Size
        G2Size
        RetainedSketchSize = 0
        SketchIndices
        CorrelationSketchHistory
        CorrelationHistoryCount = 0
        CorrelationNumerator
        CorrelationWeight = 0
        Correlation
        CorrelationUpdateCount = 0
        ArCoefficients
        HistoryCount = 0
        KalmanState
        KalmanCovariance
        KalmanInitialized = false
        MeasurementVariance = NaN
        MeasurementNumerator = 0
        MeasurementWeight = 0
        FirstKalmanGain = NaN
        RootAngles
        RootUpdateCount = 0
        FinalArtifact = struct()
    end

    methods
        function obj = ArKalmanCanceller(config)
            obj.Config = config;
            obj.initializeScalarState();
        end

        function result = push(obj, framePacket)
            obj.validateFrame(framePacket);
            if ~isequal(obj.Epoch, framePacket.Meta.Epoch)
                obj.reset(framePacket.Meta.Epoch, 'new-epoch');
            end
            if obj.VectorLength == 0
                obj.allocate(framePacket.Data);
            else
                obj.validateDimensions(framePacket.Data);
            end
            obj.FrameCount = obj.FrameCount+1;
            originalVector = [framePacket.Data.G1(:); ...
                framePacket.Data.G2(:)];
            dynamicVector = [framePacket.Data.DynamicG1(:); ...
                framePacket.Data.DynamicG2(:)];
            if isempty(obj.SketchIndices)
                [~, obj.SketchIndices] = maxk( ...
                    abs(dynamicVector).^2, obj.RetainedSketchSize);
                obj.SketchIndices = sort(obj.SketchIndices);
            end
            currentSketch = dynamicVector(obj.SketchIndices);
            obj.updateCorrelation(currentSketch, dynamicVector);

            [cleanedVector, filteredDynamic, updateApplied] = ...
                obj.filterFrame(originalVector, dynamicVector);
            obj.updateRoots(dynamicVector);
            obj.updateHistory(filteredDynamic);
            obj.Ready = updateApplied;

            if ~obj.Ready && any(strcmpi(obj.Config.WarmupPolicy, ...
                    {'hold', 'drop'}))
                result = struct('Available', false, 'Packet', struct(), ...
                    'Status', obj.getStatus());
                return;
            end
            packet = framePacket;
            packet.Data.OriginalG1 = framePacket.Data.G1;
            packet.Data.OriginalG2 = framePacket.Data.G2;
            packet.Data.G1 = reshape(cleanedVector(1:obj.G1ElementCount), ...
                obj.G1Size);
            packet.Data.G2 = reshape( ...
                cleanedVector(obj.G1ElementCount+1:end), obj.G2Size);
            packet.Data.DynamicG1 = reshape( ...
                filteredDynamic(1:obj.G1ElementCount), obj.G1Size);
            packet.Data.DynamicG2 = reshape( ...
                filteredDynamic(obj.G1ElementCount+1:end), obj.G2Size);
            packet.Meta.CancellationApplied = obj.Ready && ...
                obj.LastCancellationGain > 0;
            packet.Meta.CancellationReady = obj.Ready;
            packet.Quality.Cancellation = obj.quality();
            result = struct('Available', true, 'Packet', packet, ...
                'Status', obj.getStatus());
        end

        function reset(obj, epoch, reason) %#ok<INUSD>
            if nargin < 2
                epoch = NaN;
            end
            obj.Epoch = epoch;
            obj.VectorLength = 0;
            obj.G1ElementCount = 0;
            obj.G1Size = [];
            obj.G2Size = [];
            obj.initializeScalarState();
        end

        function status = getStatus(obj)
            if obj.Ready
                state = 'ready';
            else
                state = 'warming';
            end
            status = struct('State', state, 'Ready', obj.Ready, ...
                'Epoch', obj.Epoch, 'FrameCount', obj.FrameCount, ...
                'WarmupCount', min(obj.FrameCount, obj.Config.WarmupFrames), ...
                'WarmupRequired', obj.Config.WarmupFrames, ...
                'CancellationGain', obj.LastCancellationGain, ...
                'SmoothedCoherence', obj.SmoothedCoherence, ...
                'FirstKalmanGain', obj.FirstKalmanGain, ...
                'MeasurementVariance', obj.MeasurementVariance, ...
                'RootHz', obj.RootHz, ...
                'YuleWalkerRcond', obj.YuleWalkerRcond, ...
                'CorrelationUpdateCount', obj.CorrelationUpdateCount, ...
                'RootUpdateCount', obj.RootUpdateCount, ...
                'Method', 'ar-kalman');
        end

        function [frequencyHz, spectrumDb] = spectrum(obj)
            if ~all(isfinite(obj.RootAngles))
                frequencyHz = [];
                spectrumDb = [];
                return;
            end
            period = obj.Config.FramePeriodSeconds;
            frequencyHz = linspace(-1/(2*period), 1/(2*period), ...
                obj.Config.SpectrumGridSize);
            rootsForDisplay = obj.Config.SpectrumPoleRadius * ...
                exp(1i*obj.RootAngles);
            polynomial = poly(rootsForDisplay);
            coefficients = -polynomial(2:end).';
            lag = (1:obj.Config.ArOrder).';
            kernel = exp(-1i*2*pi*period*lag*frequencyHz);
            denominator = 1-coefficients.'*kernel;
            power = 1./max(abs(denominator).^2, 1e-12);
            spectrumDb = 10*log10(power/max(power));
        end

        function artifact = finalize(obj, reason)
            if nargin < 2 || isempty(reason)
                reason = 'completed';
            end
            if obj.Finalized
                artifact = obj.FinalArtifact;
                return;
            end
            [frequencyHz, spectrumDb] = obj.spectrum();
            artifact = struct( ...
                'Available', ~isempty(frequencyHz), ...
                'Type', 'ar-interference-spectrum', ...
                'Data', struct('FrequencyHz', frequencyHz, ...
                'SpectrumDb', spectrumDb, 'RootHz', obj.RootHz), ...
                'Meta', struct('Epoch', obj.Epoch, ...
                'FrameCount', obj.FrameCount, ...
                'Reason', char(reason)));
            obj.FinalArtifact = artifact;
            obj.Finalized = true;
        end
    end

    methods (Access = private)
        function initializeScalarState(obj)
            order = obj.Config.ArOrder;
            obj.FrameCount = 0;
            obj.Ready = false;
            obj.LastCancellationGain = 0;
            obj.SmoothedCoherence = 0;
            obj.RootHz = nan(order, 1);
            obj.RootAngles = nan(order, 1);
            obj.YuleWalkerRcond = NaN;
            obj.RetainedSketchSize = 0;
            obj.SketchIndices = [];
            obj.CorrelationSketchHistory = [];
            obj.CorrelationHistoryCount = 0;
            obj.CorrelationNumerator = complex(zeros(2*order, 1));
            obj.CorrelationWeight = 0;
            obj.Correlation = obj.CorrelationNumerator;
            obj.CorrelationUpdateCount = 0;
            obj.ArCoefficients = [1; zeros(order-1, 1)];
            obj.HistoryCount = 0;
            obj.KalmanState = [];
            obj.KalmanCovariance = eye(order);
            obj.KalmanInitialized = false;
            obj.MeasurementVariance = NaN;
            obj.MeasurementNumerator = 0;
            obj.MeasurementWeight = 0;
            obj.FirstKalmanGain = NaN;
            obj.RootUpdateCount = 0;
            obj.Finalized = false;
            obj.FinalArtifact = struct();
        end

        function allocate(obj, data)
            obj.G1Size = [size(data.G1, 1), size(data.G1, 2), ...
                size(data.G1, 3), size(data.G1, 4)];
            obj.G2Size = [size(data.G2, 1), size(data.G2, 2), ...
                size(data.G2, 3), size(data.G2, 4)];
            obj.G1ElementCount = numel(data.G1);
            obj.VectorLength = obj.G1ElementCount + numel(data.G2);
            order = obj.Config.ArOrder;
            obj.RetainedSketchSize = min( ...
                obj.Config.SketchSize, obj.VectorLength);
            obj.KalmanState = complex(zeros(obj.VectorLength, order));
            obj.CorrelationSketchHistory = complex(zeros( ...
                obj.RetainedSketchSize, 2*order));
        end

        function updateCorrelation(obj, currentSketch, dynamicVector)
            order = obj.Config.ArOrder;
            due = obj.CorrelationHistoryCount >= 2*order && ...
                mod(obj.FrameCount-1, ...
                obj.Config.CorrelationUpdatePeriod) == 0;
            if ~due
                return;
            end
            increment = complex(zeros(2*order, 1, 'like', dynamicVector));
            for lag = 1:2*order
                increment(lag) = ...
                    (obj.CorrelationSketchHistory(:, lag)'*currentSketch) / ...
                    numel(currentSketch);
            end
            forgetting = obj.Config.CorrelationForgetting;
            obj.CorrelationNumerator = forgetting* ...
                obj.CorrelationNumerator + increment;
            obj.CorrelationWeight = forgetting*obj.CorrelationWeight+1;
            obj.Correlation = obj.CorrelationNumerator/obj.CorrelationWeight;
            obj.CorrelationUpdateCount = obj.CorrelationUpdateCount+1;
        end

        function [cleaned, filtered, updateApplied] = ...
                filterFrame(obj, original, dynamic)
            order = obj.Config.ArOrder;
            updateApplied = false;
            usableRoots = all(isfinite(obj.RootAngles));
            warming = obj.FrameCount <= obj.Config.WarmupFrames;
            if obj.HistoryCount < order || warming || ~usableRoots
                cleaned = original;
                filtered = dynamic;
                obj.LastCancellationGain = 0;
                return;
            end

            transition = [obj.ArCoefficients.'; ...
                eye(order-1), zeros(order-1, 1)];
            predictedState = obj.KalmanState*transition.';
            predictedDynamic = predictedState(:, 1);
            innovation = dynamic-predictedDynamic;
            if ~obj.KalmanInitialized
                initialVariance = median(abs(innovation).^2)/log(2);
                obj.MeasurementVariance = max(initialVariance, eps);
                obj.KalmanCovariance = ...
                    obj.Config.KalmanInitialCovarianceRatio * ...
                    obj.MeasurementVariance*eye(order);
                obj.KalmanInitialized = true;
            end

            processVariance = obj.Config.KalmanProcessNoiseRatio * ...
                obj.MeasurementVariance;
            processCovariance = complex(zeros(order));
            processCovariance(1, 1) = processVariance;
            predictedCovariance = transition*obj.KalmanCovariance* ...
                transition' + processCovariance;
            predictedCovariance = ...
                (predictedCovariance+predictedCovariance')/2;

            dynamicPower = real(dynamic'*dynamic);
            predictionPower = real(predictedDynamic'*predictedDynamic);
            maximumPower = obj.Config.PredictionPowerLimit^2 * ...
                max(dynamicPower, eps);
            if predictionPower > maximumPower
                predictionScale = sqrt(maximumPower/predictionPower);
                predictedState(:, 1) = ...
                    predictionScale*predictedState(:, 1);
                predictedDynamic = predictedState(:, 1);
                innovation = dynamic-predictedDynamic;
                predictionPower = maximumPower;
            end

            innovationVariance = real(predictedCovariance(1, 1)) + ...
                obj.MeasurementVariance;
            kalmanGain = predictedCovariance(:, 1) / ...
                max(innovationVariance, eps);
            obj.FirstKalmanGain = real(kalmanGain(1));
            posteriorState = predictedState + innovation*kalmanGain.';
            observation = [1, zeros(1, order-1)];
            covarianceUpdate = eye(order)-kalmanGain*observation;
            posteriorCovariance = covarianceUpdate*predictedCovariance* ...
                covarianceUpdate' + kalmanGain*obj.MeasurementVariance* ...
                kalmanGain';
            obj.KalmanCovariance = ...
                (posteriorCovariance+posteriorCovariance')/2;
            obj.KalmanState = posteriorState;
            updateApplied = true;
            filtered = posteriorState(:, 1);

            dynamicVarianceScale = max( ...
                median(abs(dynamic).^2)/log(2), eps);
            innovationPower = median(abs(innovation).^2)/log(2);
            varianceSample = innovationPower - ...
                real(predictedCovariance(1, 1));
            minimumVariance = obj.Config.KalmanMinimumVarianceRatio * ...
                dynamicVarianceScale;
            maximumVariance = obj.Config.KalmanMaximumVarianceRatio * ...
                dynamicVarianceScale;
            varianceSample = min(max(varianceSample, minimumVariance), ...
                maximumVariance);
            forgetting = obj.Config.KalmanMeasurementForgetting;
            obj.MeasurementNumerator = forgetting* ...
                obj.MeasurementNumerator + varianceSample;
            obj.MeasurementWeight = forgetting*obj.MeasurementWeight+1;
            obj.MeasurementVariance = ...
                obj.MeasurementNumerator/obj.MeasurementWeight;

            if predictionPower > 0 && dynamicPower > 0
                coherence = abs(predictedDynamic'*dynamic)^2 / ...
                    (predictionPower*dynamicPower+eps);
                coherence = min(max(real(coherence), 0), 1);
            else
                coherence = 0;
            end
            coherenceForgetting = obj.Config.CoherenceForgetting;
            obj.SmoothedCoherence = coherenceForgetting* ...
                obj.SmoothedCoherence + (1-coherenceForgetting)*coherence;
            confidence = min(max((obj.SmoothedCoherence- ...
                obj.Config.CoherenceLow)/(obj.Config.CoherenceHigh- ...
                obj.Config.CoherenceLow), 0), 1);
            obj.LastCancellationGain = ...
                obj.Config.MaximumCancellation*confidence;
            posteriorInterference = posteriorState(:, 1);
            cancellationInterference = predictedDynamic + ...
                obj.Config.KalmanPosteriorCancellationFraction * ...
                (posteriorInterference-predictedDynamic);
            cleaned = original-obj.LastCancellationGain*cancellationInterference;
        end

        function updateRoots(obj, dynamicVector)
            order = obj.Config.ArOrder;
            due = obj.CorrelationUpdateCount > 0 && ...
                obj.FrameCount >= obj.Config.WarmupFrames && ...
                (obj.FrameCount == obj.Config.WarmupFrames || ...
                mod(obj.FrameCount-obj.Config.WarmupFrames, ...
                obj.Config.RootUpdatePeriod) == 0);
            if ~due
                return;
            end
            delayedMatrix = complex(zeros(order, order, ...
                'like', dynamicVector));
            target = complex(zeros(order, 1, 'like', dynamicVector));
            for equation = 1:order
                targetLag = order+equation;
                target(equation) = obj.Correlation(targetLag);
                for coefficient = 1:order
                    delayedMatrix(equation, coefficient) = ...
                        obj.Correlation(targetLag-coefficient);
                end
            end
            loading = obj.Config.DiagonalLoading * ...
                max(norm(delayedMatrix, 'fro')/order, eps);
            loadedMatrix = delayedMatrix + ...
                loading*eye(order, 'like', delayedMatrix);
            obj.YuleWalkerRcond = rcond(loadedMatrix);
            if obj.YuleWalkerRcond >= obj.Config.MinimumYuleWalkerRcond
                candidateCoefficients = loadedMatrix\target;
                candidateRoots = roots([1; -candidateCoefficients(:)]);
            else
                candidateRoots = [];
            end
            usable = numel(candidateRoots) == order && ...
                all(isfinite(candidateRoots)) && ...
                all(abs(candidateRoots) > 0.05) && ...
                all(abs(candidateRoots) < 20);
            if usable
                candidateRoots = candidateRoots./abs(candidateRoots);
                stablePolynomial = poly(candidateRoots);
                obj.ArCoefficients = -stablePolynomial(2:end).';
                obj.RootAngles = sort(angle(candidateRoots));
                obj.RootHz = obj.RootAngles / ...
                    (2*pi*obj.Config.FramePeriodSeconds);
            end
            obj.RootUpdateCount = obj.RootUpdateCount+1;
        end

        function updateHistory(obj, filteredDynamic)
            order = obj.Config.ArOrder;
            if ~obj.Ready
                obj.KalmanState(:, 2:end) = obj.KalmanState(:, 1:end-1);
                obj.KalmanState(:, 1) = filteredDynamic;
            end
            obj.HistoryCount = min(obj.HistoryCount+1, order);
            obj.CorrelationSketchHistory(:, 2:end) = ...
                obj.CorrelationSketchHistory(:, 1:end-1);
            obj.CorrelationSketchHistory(:, 1) = ...
                filteredDynamic(obj.SketchIndices);
            obj.CorrelationHistoryCount = min( ...
                obj.CorrelationHistoryCount+1, 2*order);
        end

        function value = quality(obj)
            value = struct('Method', 'ar-kalman', ...
                'Ready', obj.Ready, ...
                'WarmupCount', min(obj.FrameCount, obj.Config.WarmupFrames), ...
                'WarmupRequired', obj.Config.WarmupFrames, ...
                'CancellationGain', obj.LastCancellationGain, ...
                'SmoothedCoherence', obj.SmoothedCoherence, ...
                'FirstKalmanGain', obj.FirstKalmanGain, ...
                'MeasurementVariance', obj.MeasurementVariance, ...
                'RootHz', obj.RootHz, ...
                'YuleWalkerRcond', obj.YuleWalkerRcond);
        end

        function validateDimensions(obj, data)
            g1Size = [size(data.G1, 1), size(data.G1, 2), ...
                size(data.G1, 3), size(data.G1, 4)];
            g2Size = [size(data.G2, 1), size(data.G2, 2), ...
                size(data.G2, 3), size(data.G2, 4)];
            if ~isequal(g1Size, obj.G1Size) || ~isequal(g2Size, obj.G2Size)
                error('ltecancel:ArKalmanCanceller:FrameSizeChanged', ...
                    'CSI frame dimensions changed without an epoch reset.');
            end
        end
    end

    methods (Static, Access = private)
        function validateFrame(packet)
            fields = {'G1', 'G2', 'DynamicG1', 'DynamicG2'};
            if ~isstruct(packet) || ~isfield(packet, 'Data') || ...
                    ~all(isfield(packet.Data, fields)) || ...
                    ~isfield(packet, 'Meta') || ...
                    ~isfield(packet.Meta, 'Epoch')
                error('ltecancel:ArKalmanCanceller:InvalidFrame', ...
                    'Input is not a valid CSI frame packet.');
            end
        end
    end
end
