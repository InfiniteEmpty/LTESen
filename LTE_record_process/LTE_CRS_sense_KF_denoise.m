%% LTE CRS sensing with frame-rate AR-Kalman interference cancellation
clear;
clc;
close all;

baseDirectory = 'experiment_data/rx_signal';
dateCode = '20260711';
recordIndex = 7;
rootDirectory = fullfile(baseDirectory, ['LTE_' dateCode]);
recordName = sprintf('LTE_%s_%06d', dateCode, recordIndex);

dataFile = lteio.openRecording(rootDirectory, recordName, 'auto');
config = defaultLteSenseConfig();
config.Cancellation.Method = 'ar-kalman';
[summary, pipeline] = runLteCrsSense(dataFile, config);
disp(summary);

if config.Display.Enabled
    ltecancel.plotArSpectrum( ...
        pipeline.Canceller, config.Display.FigureVisible);
end
