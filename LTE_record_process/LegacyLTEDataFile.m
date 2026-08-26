classdef LegacyLTEDataFile < IQDataFile
%LEGACYLTEDATAFILE Reader for the project's legacy GNU Radio .bin files.
%
%   obj = LegacyLTEDataFile(filePath)
%
% The data type is read from the optional _tp_<type> filename field. If no
% type is present in the filename, int16 is used.

    properties (SetAccess = private)
        date = ''
        record_id = ''
        filename = ''
        metadata = struct()
    end

    methods
        function obj = LegacyLTEDataFile(filePath)
            obj@IQDataFile();

            filePath = char(filePath);
            if ~isfile(filePath)
                error('LegacyLTEDataFile:FileNotFound', ...
                    '数据文件不存在: %s', filePath);
            end

            [folder, fileName, extension] = fileparts(filePath);
            if ~strcmpi(extension, '.bin')
                error('LegacyLTEDataFile:UnsupportedPath', ...
                    '旧格式数据文件必须是 .bin 文件: %s', filePath);
            end

            tokens = regexp(fileName, ...
                ['^LTE_(\d{8})_(\d+)_fc_(\d+(?:\.\d+)?)M_' ...
                 'fs_(\d+(?:\.\d+)?)k(?:_tp_[A-Za-z][A-Za-z0-9]*)?$'], ...
                'tokens', 'once');
            typeTokens = regexp(fileName, ...
                '_tp_([A-Za-z][A-Za-z0-9]*)$', 'tokens', 'once');

            if ~isempty(tokens)
                obj.date = tokens{1};
                obj.record_id = tokens{2};
                frequency = str2double(tokens{3}) * 1e6;
                sampleRate = str2double(tokens{4}) * 1e3;
            else
                frequency = NaN;
                sampleRate = NaN;
            end

            dataType = 'int16';
            if ~isempty(typeTokens)
                dataType = lower(typeTokens{1});
            end

            datatypeInfo = IQDataFile.makeDatatypeInfo(dataType, true);
            dataType = datatypeInfo.matlab_type;

            fileInfo = dir(filePath);
            dataBytes = double(fileInfo.bytes);
            bytesPerSample = datatypeInfo.bytes_per_sample;
            if mod(dataBytes, bytesPerSample) ~= 0
                error('LegacyLTEDataFile:InvalidDataLength', ...
                    ['数据文件大小与数据类型不匹配: %s\n' ...
                     '  字节数: %.0f\n  每个复采样点字节数: %.0f'], ...
                    filePath, dataBytes, bytesPerSample);
            end

            obj.kind = 'recording';
            obj.format = 'legacy';
            obj.file_path = filePath;
            obj.data_exists = true;
            obj.data_type = dataType;
            obj.datatype = dataType;
            obj.datatype_info = datatypeInfo;
            obj.sample_rate = sampleRate;
            obj.frequency = frequency;
            obj.num_channels = 1;
            obj.sample_count = dataBytes / bytesPerSample;
            obj.data_bytes = dataBytes;
            obj.offset = 0;

            obj.filename = fileName;
            obj.metadata = struct( ...
                'date', obj.date, ...
                'record_id', obj.record_id, ...
                'filename', fileName, ...
                'folder', folder);
        end

        function info = describe(obj)
            info = describe@IQDataFile(obj);
            info.date = obj.date;
            info.record_id = obj.record_id;
            info.filename = obj.filename;
        end

        function signal = readAt(obj, from, len, normalize)
            %READAT Read interleaved IQ samples from the legacy .bin file.
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
                error('LegacyLTEDataFile:MultipleChannels', ...
                    ['当前读取接口要求每个数据文件只有一个通道；' ...
                     '多载波 collection 请分别读取对应的 stream 对象。']);
            end
            if ~obj.data_exists
                error('LegacyLTEDataFile:DataNotFound', ...
                    '数据文件不存在: %s', obj.file_path);
            end

            from = obj.validateIndex(from, 'from');
            len = double(len);
            if isscalar(len) && isinf(len)
                len = obj.sample_count - from;
            end
            len = obj.validateIndex(len, 'len');
            if from > obj.sample_count
                error('LegacyLTEDataFile:OffsetOutOfRange', ...
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
                    error('LegacyLTEDataFile:FileOpen', ...
                        '无法打开文件: %s', obj.file_path);
                end
                cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
                if fseek(fid, byteOffset, 'bof') ~= 0
                    error('LegacyLTEDataFile:FseekError', ...
                        '无法定位到字节偏移 %.0f: %s', ...
                        byteOffset, obj.file_path);
                end
                raw = fread(fid, scalarCount, ['*' info.matlab_type], ...
                    0, info.machine_format);
                if numel(raw) ~= scalarCount
                    error('LegacyLTEDataFile:UnexpectedEOF', ...
                        ['文件提前结束：期望读取 %.0f 个实数样本，' ...
                         '实际读取 %.0f 个。'], ...
                        scalarCount, numel(raw));
                end
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
end
