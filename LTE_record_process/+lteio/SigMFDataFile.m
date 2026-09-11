classdef SigMFDataFile < lteio.IQDataFile
%SIGMFDATAFILE Reader for one SigMF data/meta pair.
%
%   obj = SigMFDataFile(rootDir, recordName)
%
% RECORDNAME must not include a suffix. The constructor resolves:
%   rootDir/recordName.sigmf-data
%   rootDir/recordName.sigmf-meta
%
% SigMF collections are handled by SigMFCollection.

    properties (SetAccess = private)
        root_dir = ''
        record_name = ''
        meta_file = ''
        metadata = struct()
        global_metadata = struct()
        captures = struct([])
        annotations = struct([])
        start_time_utc = ''
        sample_start = 0
        trailing_bytes = 0
        sha512 = ''
    end

    methods
        function obj = SigMFDataFile(rootDir, recordName)
            obj@lteio.IQDataFile();

            if nargin < 2 || isempty(rootDir) || isempty(recordName)
                error('SigMFDataFile:MissingPath', ...
                    '必须指定根目录和不含后缀的 SigMF 文件名称。');
            end
            rootDir = char(rootDir);
            recordName = char(recordName);

            if ~isfolder(rootDir)
                error('SigMFDataFile:RootNotFound', ...
                    'SigMF 根目录不存在: %s', rootDir);
            end
            [~, ~, extension] = fileparts(recordName);
            if ~isempty(extension) || contains(recordName, filesep) || ...
                    contains(recordName, '/') || contains(recordName, '\\')
                error('SigMFDataFile:InvalidRecordName', ...
                    'recordName 必须是不含路径和后缀的文件名称: %s', recordName);
            end

            obj.root_dir = rootDir;
            obj.record_name = recordName;
            obj.file_path = fullfile(rootDir, [recordName '.sigmf-data']);
            obj.meta_file = fullfile(rootDir, [recordName '.sigmf-meta']);
            obj.loadRecording();
        end

        function info = describe(obj)
            info = describe@lteio.IQDataFile(obj);
            info.root_dir = obj.root_dir;
            info.record_name = obj.record_name;
            info.meta_file = obj.meta_file;
            info.start_time_utc = obj.start_time_utc;
            info.sample_start = obj.sample_start;
            info.sha512 = obj.sha512;
        end

        function signal = readAt(obj, from, len, normalize)
            %READAT Read interleaved IQ samples from the SigMF data file.
            if nargin < 2 || isempty(from)
                from = 0;
            end
            if nargin < 3 || isempty(len)
                len = Inf;
            end
            if nargin < 4 || isempty(normalize)
                normalize = false;
            end

            obj.assertRecording();
            if obj.num_channels ~= 1
                error('SigMFDataFile:MultipleChannels', ...
                    ['当前读取接口要求每个数据文件只有一个通道；' ...
                     '多载波 collection 请分别读取对应的 stream 对象。']);
            end
            if ~obj.data_exists
                error('SigMFDataFile:DataNotFound', ...
                    '数据文件不存在: %s', obj.file_path);
            end

            from = obj.validateIndex(from, 'from');
            len = double(len);
            if isscalar(len) && isinf(len)
                len = obj.sample_count - from;
            end
            len = obj.validateIndex(len, 'len');
            if from > obj.sample_count
                error('IQDataFile:OffsetOutOfRange', ...
                    'from=%.0f 超过文件采样数 %.0f。', from, obj.sample_count);
            end
            len = min(len, obj.sample_count - from);

            info = obj.datatype_info;
            byteOffset = from * info.bytes_per_sample * obj.num_channels;
            scalarCount = info.components_per_sample * len;
            if scalarCount == 0
                signal = zeros(0, 1);
                return;
            end

            % memmapfile is safe when the file byte order matches the host.
            % Big-endian data falls back to fread with its byte order.
            if obj.canUseMemmap(info)
                mapping = memmapfile(obj.file_path, ...
                    'Format', {info.matlab_type, ...
                    [info.components_per_sample, len], 'samples'}, ...
                    'Offset', byteOffset, 'Repeat', 1, 'Writable', false);
                raw = mapping.Data.samples;
                raw = raw(:);
            else
                fid = fopen(obj.file_path, 'rb');
                if fid == -1
                    error('SigMFDataFile:FileOpen', ...
                        '无法打开文件: %s', obj.file_path);
                end
                cleanup = onCleanup(@() fclose(fid));
                if fseek(fid, byteOffset, 'bof') ~= 0
                    error('SigMFDataFile:FseekError', ...
                        '无法定位到字节偏移 %.0f: %s', ...
                        byteOffset, obj.file_path);
                end
                raw = fread(fid, scalarCount, ['*' info.matlab_type], ...
                    0, info.machine_format);
                if numel(raw) ~= scalarCount
                    error('SigMFDataFile:UnexpectedEOF', ...
                        ['文件提前结束：期望读取 %.0f 个实数样本，' ...
                         '实际读取 %.0f 个。'], ...
                        scalarCount, numel(raw));
                end
                clear cleanup;
            end

            raw = double(raw);
            if info.is_complex
                signal = raw(1:2:end) + 1i * raw(2:2:end);
            else
                signal = raw;
            end
            signal = signal(:);

            if normalize && info.is_integer
                if info.is_unsigned
                    scale = 2^info.bits_per_scalar;
                    signal = (signal - scale / 2) / (scale / 2);
                else
                    scale = 2^(info.bits_per_scalar - 1);
                    signal = signal / scale;
                end
            end
        end
    end

    methods (Access = private)
        function loadRecording(obj)
            if ~isfile(obj.meta_file)
                error('SigMFDataFile:MetadataNotFound', ...
                    '元数据文件不存在: %s', obj.meta_file);
            end

            raw = lteio.SigMFDataFile.readJson(obj.meta_file);
            globalMetadata = lteio.SigMFDataFile.getJsonField( ...
                raw, 'global', struct());
            captureList = lteio.SigMFDataFile.getJsonField( ...
                raw, 'captures', struct([]));
            annotationList = lteio.SigMFDataFile.getJsonField( ...
                raw, 'annotations', struct([]));

            datatype = lteio.SigMFDataFile.toChar( ...
                lteio.SigMFDataFile.getJsonField( ...
                globalMetadata, 'core:datatype', ''));
            if isempty(datatype)
                error('SigMFDataFile:MissingDatatype', ...
                    'SigMF 元数据缺少 core:datatype: %s', obj.meta_file);
            end
            datatypeInfo = lteio.IQDataFile.makeDatatypeInfo(datatype);

            numChannels = lteio.SigMFDataFile.getJsonField( ...
                globalMetadata, 'core:num_channels', 1);
            if isempty(numChannels)
                numChannels = 1;
            end
            numChannels = double(numChannels);

            trailingBytes = lteio.SigMFDataFile.getJsonField( ...
                globalMetadata, 'core:trailing_bytes', 0);
            if isempty(trailingBytes)
                trailingBytes = 0;
            end
            trailingBytes = double(trailingBytes);

            capture = struct();
            if ~isempty(captureList)
                capture = captureList(1);
            end
            frequency = lteio.SigMFDataFile.getJsonField( ...
                capture, 'core:frequency', NaN);
            startTimeUtc = lteio.SigMFDataFile.toChar( ...
                lteio.SigMFDataFile.getJsonField( ...
                capture, 'core:datetime', ''));
            sampleStart = lteio.SigMFDataFile.getJsonField( ...
                capture, 'core:sample_start', 0);
            sampleRate = lteio.SigMFDataFile.getJsonField( ...
                globalMetadata, 'core:sample_rate', NaN);

            dataExists = isfile(obj.file_path);
            dataBytes = NaN;
            sampleCount = NaN;
            if dataExists
                dataInfo = dir(obj.file_path);
                dataBytes = double(dataInfo.bytes);
                usableBytes = dataBytes - trailingBytes;
                bytesPerSample = datatypeInfo.bytes_per_sample * numChannels;
                if usableBytes < 0 || mod(usableBytes, bytesPerSample) ~= 0
                    error('SigMFDataFile:InvalidDataLength', ...
                        ['数据文件长度与元数据不匹配:\n' ...
                         '  文件: %s\n  字节数: %.0f\n' ...
                         '  每个样本字节数: %.0f\n  通道数: %.0f'], ...
                        obj.file_path, dataBytes, datatypeInfo.bytes_per_sample, ...
                        numChannels);
                end
                sampleCount = usableBytes / bytesPerSample;
            end

            obj.kind = 'recording';
            obj.format = 'sigmf';
            obj.data_exists = dataExists;
            obj.data_type = datatypeInfo.matlab_type;
            obj.datatype = datatype;
            obj.datatype_info = datatypeInfo;
            obj.sample_rate = double(sampleRate);
            obj.frequency = double(frequency);
            obj.num_channels = numChannels;
            obj.sample_count = sampleCount;
            obj.data_bytes = dataBytes;
            obj.offset = 0;

            obj.metadata = raw;
            obj.global_metadata = globalMetadata;
            obj.captures = captureList;
            obj.annotations = annotationList;
            obj.start_time_utc = startTimeUtc;
            obj.sample_start = double(sampleStart);
            obj.trailing_bytes = trailingBytes;
            obj.sha512 = lteio.SigMFDataFile.toChar( ...
                lteio.SigMFDataFile.getJsonField( ...
                globalMetadata, 'core:sha512', ''));
        end
    end

    methods (Static, Access = private)
        function raw = readJson(path)
            try
                raw = jsondecode(fileread(path));
            catch err
                error('SigMFDataFile:JsonReadError', ...
                    '无法读取 SigMF JSON 文件: %s\n%s', path, err.message);
            end
        end

        function value = getJsonField(s, name, defaultValue)
            value = defaultValue;
            if ~isstruct(s)
                return;
            end

            % MATLAB jsondecode changes core:datatype to core_datatype.
            candidates = {name, strrep(name, ':', '_'), ...
                matlab.lang.makeValidName(name)};
            for k = 1:numel(candidates)
                if isfield(s, candidates{k})
                    value = s.(candidates{k});
                    return;
                end
            end
        end

        function value = toChar(value)
            if isempty(value)
                value = '';
            elseif ischar(value)
                value = value(:).';
            elseif isstring(value)
                value = char(value);
            else
                value = char(string(value));
            end
        end
    end
end
