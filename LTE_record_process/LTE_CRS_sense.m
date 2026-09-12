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
% config.Cancellation.Method = 'passthrough';
% Frame-rate AR-Kalman interference cancellation
config.Cancellation.Method = 'ar-kalman';
summary = runLteCrsSense(dataFile, config);
disp(summary);
