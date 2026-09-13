function tests = test_ModularPipelineBuffers
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
testDirectory = fileparts(mfilename('fullpath'));
projectDirectory = fileparts(fileparts(testDirectory));
testCase.applyFixture(matlab.unittest.fixtures.PathFixture(projectDirectory));
testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
    fullfile(fileparts(testDirectory), 'helpers')));
end

function testTimebaseUsesExplicitSampleDomains(testCase)
lock = makeLock(3);
timebase = ltesync.Timebase(lock);
first = timebase.currentMeta();
timebase.advance(-1);
second = timebase.currentMeta();
verifyEqual(testCase, first.Epoch, 3);
verifyEqual(testCase, first.RawStartSample0, 1000);
verifyEqual(testCase, second.RawStartSample0, 1000+30720-2);
verifyEqual(testCase, second.SubframeNumber, 1);
verifyEqual(testCase, second.Sequence, 1);
end

function testReportedSdrRateIsSnappedForResampling(testCase)
reportedRate = 15360000.011967678;
verifyEqual(testCase, lteio.processingSampleRate(reportedRate), 15360000);
end

function testAssemblerEmitsOnlyCompleteFrame(testCase)
assembler = ltebuffer.CsiFrameAssembler();
for subframe = 0:8
    result = assembler.process(ltepipe.Message.fromPacket( ...
        makeSubframe(1, subframe, subframe)));
    verifyFalse(testCase, result.Message.HasPacket);
end
result = assembler.process(ltepipe.Message.fromPacket( ...
    makeSubframe(1, 9, 9)));
verifyTrue(testCase, result.Message.HasPacket);
verifyEqual(testCase, result.Message.Packet.Data.G1, ...
    reshape(repelem(0:9, 2), 1, 20));
verifyEqual(testCase, result.Message.Packet.Meta.EndSequence, 9);
end

function testAssemblerDoesNotBridgeSequenceGap(testCase)
assembler = ltebuffer.CsiFrameAssembler();
for subframe = 0:3
    assembler.process(ltepipe.Message.fromPacket( ...
        makeSubframe(1, subframe, subframe)));
end
result = assembler.process(ltepipe.Message.fromPacket( ...
    makeSubframe(1, 5, 5)));
verifyFalse(testCase, result.Message.HasPacket);
verifyEqual(testCase, assembler.BufferedSubframes, 0);
verifyEqual(testCase, assembler.DroppedPartialFrames, 1);
for subframe = 0:9
    result = assembler.process(ltepipe.Message.fromPacket( ...
        makeSubframe(1, 10+subframe, subframe)));
end
verifyTrue(testCase, result.Message.HasPacket);
verifyEqual(testCase, result.Message.Packet.Meta.Sequence, 10);
end

function testFrameWindowPreservesTimeOrderAndAntennas(testCase)
window = ltebuffer.FrameWindow(3, 3);
for frameIndex = 0:2
    packet = makeFrame(2, frameIndex*10, frameIndex);
    result = window.push(packet, 'G1');
end
verifyTrue(testCase, result.Available);
verifySize(testCase, result.Data, [1, 6, 2]);
verifyEqual(testCase, squeeze(result.Data(1, :, 1)), ...
    [0, 0, 1, 1, 2, 2]);
verifyEqual(testCase, squeeze(result.Data(1, :, 2)), ...
    [100, 100, 101, 101, 102, 102]);
end

function testArKalmanWarmupBypassesAndEpochResets(testCase)
config = defaultLteSenseConfig();
config.Cancellation.ArOrder = 2;
config.Cancellation.WarmupFrames = 6;
canceller = ltecancel.ArKalmanCanceller(config.Cancellation);
for frameIndex = 0:2
    packet = makeCancellationFrame(1, frameIndex*10, frameIndex);
    result = canceller.process(ltepipe.Message.fromPacket(packet));
    verifyTrue(testCase, result.Message.HasPacket);
    verifyFalse(testCase, ...
        result.Message.Packet.Meta.CancellationReady);
    verifyEqual(testCase, ...
        result.Message.Packet.Data.G1, packet.Data.G1);
end
verifyEqual(testCase, canceller.FrameCount, 3);
packet = makeCancellationFrame(2, 0, 0);
canceller.process(ltepipe.Message.fromPacket(packet));
verifyEqual(testCase, canceller.Epoch, 2);
verifyEqual(testCase, canceller.FrameCount, 1);
end

function testArKalmanEmitsDirectSpectrumEveryTenFrames(testCase)
config = defaultLteSenseConfig();
config.Cancellation.ArOrder = 1;
config.Cancellation.WarmupFrames = 3;
config.Cancellation.RootUpdatePeriod = 1;
config.Cancellation.SpectrumUpdatePeriodFrames = 10;
canceller = ltecancel.ArKalmanCanceller(config.Cancellation);

for frameIndex = 0:19
    packet = makeCancellationFrame(1, frameIndex*10, frameIndex);
    result = canceller.process(ltepipe.Message.fromPacket(packet));
    if any(frameIndex+1 == [10, 20])
        verifyNumElements(testCase, result.Message.Artifacts, 1);
        artifact = result.Message.Artifacts{1};
        verifyEqual(testCase, artifact.Type, ...
            'ar-interference-spectrum');
        verifyEqual(testCase, artifact.Meta.Reason, 'periodic');
        verifyEqual(testCase, artifact.Meta.FrameCount, frameIndex+1);
        verifyEqual(testCase, artifact.Data.FrequencyAxis, 'asinh');
        verifyEqual(testCase, ...
            artifact.Data.FrequencyHz((end+1)/2), 0, 'AbsTol', eps);
        centerStep = artifact.Data.FrequencyHz((end+3)/2);
        edgeStep = artifact.Data.FrequencyHz(end) - ...
            artifact.Data.FrequencyHz(end-1);
        verifyLessThan(testCase, centerStep, edgeStep);
    else
        verifyEmpty(testCase, result.Message.Artifacts);
    end
end
verifyEqual(testCase, canceller.SpectrumUpdateCount, 2);
verifyTrue(testCase, all(isfinite(canceller.RootMagnitudes)));
end

function testArKalmanDoesNotProjectNearOneRoot(testCase)
config = defaultLteSenseConfig();
config.Cancellation.ArOrder = 1;
config.Cancellation.WarmupFrames = 3;
config.Cancellation.RootUpdatePeriod = 1;
config.Cancellation.DiagonalLoading = 0;
canceller = ltecancel.ArKalmanCanceller(config.Cancellation);

amplitudeRatio = 0.99;
cyclesPerFrame = 1e-3;
for frameIndex = 0:2
    packet = makeCancellationFrame(1, frameIndex*10, frameIndex);
    adjustment = amplitudeRatio^frameIndex * exp(1i*2*pi* ...
        (cyclesPerFrame-0.13)*frameIndex);
    packet.Data.G1 = adjustment*packet.Data.G1;
    packet.Data.G2 = adjustment*packet.Data.G2;
    packet.Data.DynamicG1 = adjustment*packet.Data.DynamicG1;
    packet.Data.DynamicG2 = adjustment*packet.Data.DynamicG2;
    canceller.process(ltepipe.Message.fromPacket(packet));
end

verifyEqual(testCase, canceller.RootMagnitudes, 1/amplitudeRatio, ...
    'RelTol', 1e-10);
verifyEqual(testCase, canceller.RootHz, cyclesPerFrame / ...
    config.Cancellation.FramePeriodSeconds, 'AbsTol', 1e-10);
end

function testDynamicMusicSpectrumTracksPositiveCfo(testCase)
config = defaultLteSenseConfig();
config.Display.FigureVisible = 'off';
config.Music.SampleIntervalFrames = 1;
config.Music.CovarianceOrder = 8;
config.Music.SignalCount = 1;
config.Music.CorrelationForgetting = 1;
config.Music.FrequencyLimitHz = 5;
config.Music.SpectrumGridSize = 2001;
musicFigure = figure('Visible', 'off');
cleanup = onCleanup(@() close(musicFigure));
musicLayout = tiledlayout(musicFigure, 1, 2);
singularValueAxes = nexttile(musicLayout, 1);
musicAxes = nexttile(musicLayout, 2);
viewer = ltecancel.MusicSpectrumViewer( ...
    config.Music, config.Display, struct( ...
    'Spectrum', musicAxes, ...
    'SingularValues', singularValueAxes));

expectedCfoHz = 2;
cyclesPerFrame = expectedCfoHz*config.Music.FramePeriodSeconds;
for frameIndex = 0:11
    packet = makeCancellationFrame(1, frameIndex*10, frameIndex);
    adjustment = exp(1i*2*pi*(cyclesPerFrame-0.13)*frameIndex);
    packet.Data.G1 = adjustment*packet.Data.G1;
    packet.Data.G2 = adjustment*packet.Data.G2;
    packet.Data.DynamicG1 = adjustment*packet.Data.DynamicG1;
    packet.Data.DynamicG2 = adjustment*packet.Data.DynamicG2;
    viewer.process(ltepipe.Message.fromPacket(packet));
end

[~, peakIndex] = max(viewer.SpectrumDb);
verifyEqual(testCase, viewer.FrequencyHz(peakIndex), expectedCfoHz, ...
    'AbsTol', 0.01);
verifySize(testCase, viewer.SingularValues, ...
    [config.Music.CovarianceOrder, 1]);
verifyEqual(testCase, viewer.SingularValuesDb(1), 0, 'AbsTol', 1e-10);
verifyGreaterThan(testCase, viewer.SingularValuesDb(1), ...
    viewer.SingularValuesDb(2));
verifyTrue(testCase, issorted(viewer.SingularValues, 'descend'));
verifyEqual(testCase, singularValueAxes.YLabel.String, ...
    'Normalized singular value (dB)');
verifyEqual(testCase, singularValueAxes.XLim, ...
    [1, config.Music.CovarianceOrder]);
verifyEqual(testCase, viewer.SampleCount, 12);
verifyEqual(testCase, viewer.CovarianceUpdateCount, 5);
verifyEqual(testCase, viewer.UpdateCount, 5);
clear cleanup;
end

function testCancellerFinalizeIsIdempotent(testCase)
config = defaultLteSenseConfig();
canceller = ltecancel.ArKalmanCanceller(config.Cancellation);
first = canceller.finalize('completed');
second = canceller.finalize('different-reason');
verifyEqual(testCase, second, first);
verifyEmpty(testCase, first.Message.Artifacts);
verifyTrue(testCase, canceller.Finalized);
end

function testViewerBaseSharesWindowReusesAxesAndStopsOnClose(testCase)
config = defaultLteSenseConfig();
config.Display.FigureVisible = 'off';
monitorFigure = figure('Visible', config.Display.FigureVisible);
cleanup = onCleanup(@() closeIfOpen(monitorFigure));
monitorLayout = tiledlayout(monitorFigure, 1, 3);
rangeDopplerAxes = struct( ...
    'Main', nexttile(monitorLayout, 1));
arAxesGroup = struct( ...
    'Spectrum', nexttile(monitorLayout, 2), ...
    'PoleMap', nexttile(monitorLayout, 3));
rdViewer = lterd.Viewer(config.Display, rangeDopplerAxes);
arViewer = ltecancel.ArSpectrumViewer( ...
    config.Display, arAxesGroup);
verifyTrue(testCase, isa(rdViewer, 'ltevisual.ViewerBase'));
verifyTrue(testCase, isa(arViewer, 'ltevisual.ViewerBase'));

rdPacket = struct( ...
    'Type', 'range-doppler', ...
    'Data', struct( ...
        'VelocityMetersPerSecond', [-1, 1], ...
        'RangeMeters', [0, 2], ...
        'MagnitudeDb', [-20, -10; -5, 0]), ...
    'Meta', struct('Epoch', 1, 'EndSequence', 99), ...
    'Quality', struct('DisplayLimitsDb', [-30, 5]));
arArtifact = struct( ...
    'Available', true, ...
    'Type', 'ar-interference-spectrum', ...
    'Data', struct( ...
        'FrequencyHz', [-100, 0, 100], ...
        'SpectrumDb', [-20, 0, -20], ...
        'RootHz', [-20; 25], ...
        'FrequencyAxis', 'asinh', ...
        'FrequencyLinearScaleHz', 1e-2), ...
    'Meta', struct());

rdMessage = ltepipe.Message.fromPacket(rdPacket);
arMessage = ltepipe.Message.addArtifact( ...
    ltepipe.Message.none(), arArtifact);
rdResult = rdViewer.process(rdMessage);
arResult = arViewer.process(arMessage);
verifyEqual(testCase, rdResult.Message, rdMessage);
verifyEqual(testCase, arResult.Message, arMessage);
rdAxes = rdViewer.Axes.Main;
arSpectrumAxes = arViewer.Axes.Spectrum;
arPoleAxes = arViewer.Axes.PoleMap;
verifyTrue(testCase, isgraphics(rdAxes));
verifyTrue(testCase, isgraphics(arSpectrumAxes));
verifyTrue(testCase, isgraphics(arPoleAxes));
verifyNotEqual(testCase, rdAxes, arSpectrumAxes);
verifyEqual(testCase, ancestor(rdAxes, 'figure'), ...
    ancestor(arSpectrumAxes, 'figure'));

rdViewer.process(rdMessage);
arViewer.process(arMessage);
verifyEqual(testCase, rdViewer.Axes.Main, rdAxes);
verifyEqual(testCase, arViewer.Axes.Spectrum, arSpectrumAxes);
verifyEqual(testCase, arViewer.Axes.PoleMap, arPoleAxes);
verifyEqual(testCase, rdViewer.UpdateCount, 2);
verifyEqual(testCase, arViewer.UpdateCount, 2);

delete(arPoleAxes);
arStopResult = arViewer.process(ltepipe.Message.none());
verifyEqual(testCase, arStopResult.Directive, 'stop');
rdContinueResult = rdViewer.process(ltepipe.Message.none());
verifyEqual(testCase, rdContinueResult.Directive, 'continue');

close(monitorFigure);
stopResult = rdViewer.process(ltepipe.Message.none());
verifyEqual(testCase, stopResult.Directive, 'stop');
clear cleanup;
end

function testDisabledViewerWithoutAxesPassesMessagesThrough(testCase)
config = defaultLteSenseConfig();
config.Display.Enabled = false;
viewer = lterd.Viewer( ...
    config.Display, struct('Main', gobjects(0)));
message = ltepipe.Message.none();
result = viewer.process(message);
verifyEqual(testCase, result.Message, message);
verifyEqual(testCase, result.Directive, 'continue');
verifyEqual(testCase, viewer.getStatus().State, 'disabled');
end

function testPipelineHandlesResetStopAndStatusGenerically(testCase)
packet = makeTestPacket(1);
steps = { ...
    ltepipe.Result.resetDownstream( ...
        ltepipe.Message.none(), 2, 'test-gap'), ...
    ltepipe.Result.emit(packet), ...
    ltepipe.Result.stop(ltepipe.Message.none(), 'end-of-file')};
source = testsupport.ScriptedSource(steps, 'test');
firstProbe = testsupport.Probe('firstProbe', 'test');
secondProbe = testsupport.Probe('secondProbe', 'test');
config = defaultLteSenseConfig();
config.Display.Enabled = false;
config.Execution.MaximumIterations = 10;
config.Execution.Verbose = false;
pipeline = ltepipe.Pipeline(config.Execution);
pipeline.register(source);
pipeline.register(firstProbe);
pipeline.register(secondProbe);

summary = pipeline.run();
verifyEqual(testCase, summary.Iterations, 3);
verifyEqual(testCase, summary.TerminationReason, 'end-of-file');
verifyEqual(testCase, firstProbe.ResetCount, 1);
verifyEqual(testCase, secondProbe.ResetCount, 1);
verifyEqual(testCase, firstProbe.PacketCount, 1);
verifyEqual(testCase, secondProbe.PacketCount, 1);
verifyEqual(testCase, {summary.Modules.Name}, ...
    {'source', 'firstProbe', 'secondProbe'});
verifyEqual(testCase, firstProbe.LastReset.Source, 'source');
printed = evalc('ltepipe.printStatus(summary)');
verifyTrue(testCase, contains(printed, 'Modules (3):'));
verifyTrue(testCase, contains(printed, ...
    '[1] source (testsupport.ScriptedSource)'));
verifyTrue(testCase, contains(printed, 'Runtime:'));
verifyTrue(testCase, contains(printed, 'ContextKeys:'));
verifyFalse(testCase, contains(printed, '[1x3 struct]'));
end

function testPipelineRoutesFinalArtifactsThroughLaterModules(testCase)
source = testsupport.ScriptedSource({}, 'test');
emitter = testsupport.FinalizeEmitter();
probe = testsupport.Probe('artifactProbe', 'test');
config = defaultLteSenseConfig();
config.Display.Enabled = false;
config.Execution.Verbose = false;
pipeline = ltepipe.Pipeline(config.Execution);
pipeline.register(source);
pipeline.register(emitter);
pipeline.register(probe);

first = pipeline.finalize('completed');
second = pipeline.finalize('ignored');
verifyEqual(testCase, second, first);
verifyEqual(testCase, numel(first), 1);
verifyEqual(testCase, first{1}.Type, 'test-artifact');
verifyEqual(testCase, probe.ArtifactCount, 1);
verifyEqual(testCase, probe.FinalizeCount, 1);
end

function lock = makeLock(epoch)
lock = struct('Epoch', epoch, 'RawSampleRateHz', 30.72e6, ...
    'LteSampleRateHz', 15.36e6, 'RawFrameStartSample0', 1000, ...
    'Enb', struct('NFrame', 7));
end

function packet = makeSubframe(epoch, sequence, subframe)
value = double(subframe);
data = struct('G1', value*ones(1, 2), ...
    'G2', (value+20)*ones(1, 2), ...
    'DynamicG1', (value+40)*ones(1, 2), ...
    'DynamicG2', (value+60)*ones(1, 2));
meta = struct('Epoch', epoch, 'Sequence', sequence, ...
    'SubframeNumber', subframe, 'FrameNumber', floor(sequence/10), ...
    'RawStartSample0', sequence*100, ...
    'RawEndSample0', (sequence+1)*100);
packet = struct('Type', 'csi-subframe', ...
    'Data', data, 'Meta', meta, 'Quality', struct());
end

function packet = makeFrame(receiveCount, sequence, frameIndex)
g1 = zeros(1, 2, receiveCount, 1);
for receive = 1:receiveCount
    g1(:, :, receive, :) = frameIndex+100*(receive-1);
end
data = struct('G1', g1);
meta = struct('Epoch', 1, 'Sequence', sequence, ...
    'EndSequence', sequence+9, 'RawStartSample0', sequence, ...
    'RawEndSample0', sequence+10);
packet = struct('Data', data, 'Meta', meta);
end

function packet = makeCancellationFrame(epoch, sequence, frameIndex)
phase = exp(1i*2*pi*0.13*frameIndex);
g1 = phase*reshape(1:40, 2, 20);
g2 = phase*reshape(41:80, 2, 20);
data = struct('G1', g1, 'G2', g2, ...
    'DynamicG1', 0.1*g1, 'DynamicG2', 0.1*g2);
meta = struct('Epoch', epoch, 'Sequence', sequence, ...
    'EndSequence', sequence+9, 'RawStartSample0', sequence, ...
    'RawEndSample0', sequence+10);
packet = struct('Type', 'csi-frame', ...
    'Data', data, 'Meta', meta, 'Quality', struct());
end

function packet = makeTestPacket(epoch)
packet = struct('Type', 'test', 'Data', struct('Value', 1), ...
    'Meta', struct('Epoch', epoch), 'Quality', struct());
end

function closeIfOpen(figureHandle)
if isgraphics(figureHandle, 'figure')
    close(figureHandle);
end
end
