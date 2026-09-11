function figureHandle = plotArSpectrum(canceller, visible)
%PLOTARSPECTRUM Plot the spectrum identified by an AR-Kalman canceller.
if nargin < 2 || isempty(visible)
    visible = 'on';
end
[frequencyHz, spectrumDb] = canceller.spectrum();
if isempty(frequencyHz)
    figureHandle = gobjects(0);
    return;
end
status = canceller.getStatus();
figureHandle = figure('Name', 'AR-Based Interference CFO Spectrum', ...
    'Visible', visible);
plot(frequencyHz, spectrumDb, 'LineWidth', 1.2);
hold on;
stem(status.RootHz, zeros(size(status.RootHz)), ...
    'r', 'filled', 'LineWidth', 1);
hold off;
grid on;
xlim(frequencyHz([1, end]));
ylim([-60, 5]);
xlabel('CFO (Hz)');
ylabel('Normalized AR spectrum (dB)');
title('AR Interference CFO Spectrum');
legend('AR spectrum', 'AR roots', 'Location', 'best');
end
