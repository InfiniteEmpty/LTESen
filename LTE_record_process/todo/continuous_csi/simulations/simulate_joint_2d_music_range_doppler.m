%% Run the two-target AR / MUSIC / 2D-FFT comparison demonstration
simulationDirectory = fileparts(mfilename('fullpath'));
run(fullfile(simulationDirectory, 'simulate_joint_2d_ar_range_doppler.m'));
