function [summary, pipeline] = runLteCrsSense(dataFile, config)
%RUNLTECRSSENSE Run the modular LTE CRS sensing pipeline.
%   [SUMMARY, PIPELINE] = RUNLTECRSSENSE(DATAFILE, CONFIG) processes an
%   IQDataFile-compatible source. CONFIG defaults to defaultLteSenseConfig.

if nargin < 2 || isempty(config)
    config = defaultLteSenseConfig();
end
pipeline = LteSensePipeline(dataFile, config);
summary = pipeline.run();
end
