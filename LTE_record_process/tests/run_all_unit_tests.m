%% Run the active unit tests
clear;
clc;
testDirectory = fileparts(mfilename('fullpath'));
projectDirectory = fileparts(testDirectory);
addpath(projectDirectory);

results = runtests(fullfile(testDirectory, 'unit'), ...
    'IncludeSubfolders', true);
disp(table(results));
assertSuccess(results);
