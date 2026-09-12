%% LTE CRS sensing
clear;
clc;
close all;

baseDirectory = 'experiment_data/rx_signal';
dateCode = '20260711';
recordIndex = 12;
rootDirectory = fullfile(baseDirectory, ['LTE_' dateCode]);
recordName = sprintf('LTE_%s_%06d', dateCode, recordIndex);

dataFile = lteio.openRecording(rootDirectory, recordName, 'auto');
config = defaultLteSenseConfig();
% Modular processing pipeline
config.Cancellation.Method = 'passthrough';
% Frame-rate AR-Kalman interference cancellation
% config.Cancellation.Method = 'ar-kalman';

figureManager = ltevisual.FigureManager(config.Display);
viewAxes = figureManager.createViews(config.Display.Views);

pipeline = ltepipe.Pipeline(config.Execution);
pipeline.register(ltetracking.Receiver(dataFile, config));
pipeline.register(ltebuffer.CsiFrameAssembler());

switch lower(char(config.Cancellation.Method))
    case {'ar-kalman', 'arkalman', 'kf'}
        pipeline.register( ...
            ltecancel.ArKalmanCanceller(config.Cancellation));
        pipeline.register(ltecancel.ArSpectrumViewer( ...
            config.Display, viewAxes.ArSpectrum));
    case {'none', 'passthrough'}
    otherwise
        error('LTE_CRS_sense:UnknownCanceller', ...
            'Unknown interference cancellation method: %s', ...
            config.Cancellation.Method);
end

pipeline.register(lterd.Processor(config.RangeDoppler));
pipeline.register(lterd.Viewer( ...
    config.Display, viewAxes.RangeDoppler));
summary = pipeline.run();
ltepipe.printStatus(summary);
