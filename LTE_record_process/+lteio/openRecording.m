function dataFile = openRecording(rootDirectory, recordName, format)
%OPENRECORDING Open a recording through the common IQDataFile interface.
%   FORMAT is 'auto' (default), 'sigmf', or 'legacy'. Auto prefers a SigMF
%   metadata/data pair and otherwise delegates filename resolution to the
%   legacy reader.

if nargin < 3 || isempty(format)
    format = 'auto';
end
format = lower(char(format));
switch format
    case 'auto'
        sigmfMetadata = fullfile(rootDirectory, ...
            [char(recordName) '.sigmf-meta']);
        sigmfData = fullfile(rootDirectory, ...
            [char(recordName) '.sigmf-data']);
        if isfile(sigmfMetadata) && isfile(sigmfData)
            dataFile = lteio.SigMFDataFile(rootDirectory, recordName);
        else
            dataFile = lteio.LegacyLTEDataFile(rootDirectory, recordName);
        end
    case 'sigmf'
        dataFile = lteio.SigMFDataFile(rootDirectory, recordName);
    case 'legacy'
        dataFile = lteio.LegacyLTEDataFile(rootDirectory, recordName);
    otherwise
        error('lteio:openRecording:UnknownFormat', ...
            'Unknown recording format: %s', format);
end
end
