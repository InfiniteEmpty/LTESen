function nominalRateHz = processingSampleRate(reportedRateHz)
%PROCESSINGSAMPLERATE Convert SDR metadata rates to integer DSP rates.
%   Some UHD/SigMF writers serialize a nominal integer sample rate with a
%   tiny floating-point clock error. MATLAB resample requires integer rate
%   arguments, while LTE frame indexing also assumes the nominal DSP rate.

validateattributes(reportedRateHz, {'numeric'}, ...
    {'scalar', 'real', 'finite', 'positive'});
nominalRateHz = round(double(reportedRateHz));
if nominalRateHz <= 0
    error('lteio:processingSampleRate:InvalidRate', ...
        'The rounded processing sample rate must be positive.');
end
end
