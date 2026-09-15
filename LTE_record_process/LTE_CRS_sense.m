%% LTE CRS sensing

clear;
clc;
close all;

%% Basic config

baseDirectory = '../experiment_data/rx_signal';
dateCode = '20260825';
recordIndex = 2;
rootDirectory = fullfile(baseDirectory, ['LTE_' dateCode]);
recordName = sprintf('LTE_%s_%06d', dateCode, recordIndex);

dataFile = lteio.openRecording(rootDirectory, recordName, 'auto');
config = defaultLteSenseConfig();

%% Figure init

rangeDopplerAxes = struct('Main', gobjects(0));
musicAxes = struct( ...
    'Spectrum', gobjects(0), ...
    'SingularValues', gobjects(0));
if config.Display.Enabled
    monitorFigure = figure( ...
        'Name', 'LTE Sensing Monitor', ...
        'NumberTitle', 'off', ...
        'Visible', config.Display.FigureVisible);
    monitorLayout = tiledlayout(monitorFigure, 2, 2);
    rangeDopplerAxes.Main = nexttile(monitorLayout, 1, [2, 1]);
    musicAxes.SingularValues = nexttile(monitorLayout, 2);
    musicAxes.Spectrum = nexttile(monitorLayout, 4);
end

%% Pipeline struct

pipeline = ltepipe.Pipeline(config.Execution);
pipeline.register(ltetracking.Receiver(dataFile, config));
pipeline.register(ltebuffer.CsiFrameAssembler());

pipeline.register(ltecancel.MusicSpectrumViewer( ...
    config.Music, config.Display, musicAxes));

% pipeline.register(ltecancel.ArKalmanCanceller(config.Cancellation));
% pipeline.register(ltecancel.ArSpectrumViewer( ...
%     config.Display, struct('Spectrum', arSpectrumAxes)));

pipeline.register(lterd.Processor(config.RangeDoppler));
pipeline.register(lterd.Viewer( ...
    config.Display, rangeDopplerAxes));

%% Run

summary = pipeline.run();
ltepipe.printStatus(summary);
