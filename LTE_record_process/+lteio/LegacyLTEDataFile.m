classdef LegacyLTEDataFile < lteio.IQDataFile
%LEGACYLTEDATAFILE Reader for the project's legacy GNU Radio .bin files.
%
%   obj = LegacyLTEDataFile(path, prefix)
%   obj = LegacyLTEDataFile(filePath)
%
% PATH may be a directory. In that form PREFIX is used to search for one
% matching PREFIX_*.bin file. A direct file path remains supported for
% compatibility. The filename format is:
%   PREFIX_key_value_key_value.bin
%
% The first prefix used by this project is, for example,
%   LTE_20260709_000004
% Date and record ID are part of the prefix; the remaining metadata are
% parsed as extensible key-value pairs. Missing tp/type defaults to int16.

    properties (SetAccess = private)
        prefix = ''
        date = ''
        record_id = ''
        filename = ''
        metadata = struct()
        metadata_keys = {}
        metadata_values = {}
    end

    methods
        function obj = LegacyLTEDataFile(path, prefix)
            obj@lteio.IQDataFile();

            if nargin < 2
                prefix = '';
            end
            [filePath, prefix] = lteio.LegacyLTEDataFile.resolveFile(path, prefix);

            [~, fileName, extension] = fileparts(filePath);
            if ~strcmpi(extension, '.bin')
                error('LegacyLTEDataFile:UnsupportedPath', ...
                    '旧格式数据文件必须是 .bin 文件: %s', filePath);
            end

            [metadata, keys, values] = ...
                lteio.LegacyLTEDataFile.parseMetadata(fileName, prefix);

            obj.prefix = prefix;
            obj.metadata = metadata;
            obj.metadata_keys = keys;
            obj.metadata_values = values;
            obj.date = lteio.LegacyLTEDataFile.getMetadata(metadata, ...
                {'date'});
            obj.record_id = lteio.LegacyLTEDataFile.getMetadata(metadata, ...
                {'id', 'record_id', 'recordid'});
            [prefixDate, prefixId] = ...
                lteio.LegacyLTEDataFile.parseIndexedPrefix(prefix);
            if isempty(obj.date)
                obj.date = prefixDate;
            end
            if isempty(obj.record_id)
                obj.record_id = prefixId;
            end

            frequency = lteio.LegacyLTEDataFile.parseQuantity( ...
                lteio.LegacyLTEDataFile.getMetadata(metadata, ...
                {'fc', 'freq', 'frequency'}));
            sampleRate = lteio.LegacyLTEDataFile.parseQuantity( ...
                lteio.LegacyLTEDataFile.getMetadata(metadata, ...
                {'fs', 'sr', 'sample_rate', 'samplerate'}));

            dataType = lteio.LegacyLTEDataFile.getMetadata(metadata, ...
                {'tp', 'type', 'datatype', 'data_type'});
            if isempty(dataType)
                dataType = 'int16';
            end

            datatypeInfo = lteio.IQDataFile.makeDatatypeInfo(dataType, true);
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
        end

        function info = describe(obj)
            info = describe@lteio.IQDataFile(obj);
            info.prefix = obj.prefix;
            info.date = obj.date;
            info.record_id = obj.record_id;
            info.filename = obj.filename;
            info.metadata = obj.metadata;
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
                cleanup = onCleanup(@() fclose(fid));
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

    methods (Static, Access = private)
        function [filePath, prefix] = resolveFile(path, prefix)
            path = char(path);
            prefix = char(prefix);

            if isfolder(path)
                if isempty(strtrim(prefix))
                    error('LegacyLTEDataFile:MissingPrefix', ...
                        '当输入为目录时，必须指定文件前缀。');
                end

                prefix = strtrim(prefix);
                exactPath = fullfile(path, [prefix '.bin']);
                if isfile(exactPath)
                    filePath = exactPath;
                    [~, exactName] = fileparts(exactPath);
                    prefix = lteio.LegacyLTEDataFile.inferPrefix(exactName);
                    return;
                end

                listing = dir(fullfile(path, [prefix '_*.bin']));
                listing = listing(~[listing.isdir]);
                if isempty(listing)
                    error('LegacyLTEDataFile:FileNotFound', ...
                        '目录中没有找到前缀为 %s 的 .bin 文件: %s', ...
                        prefix, path);
                end
                if numel(listing) > 1
                    warning('LegacyLTEDataFile:MultipleMatches', ...
                        '找到 %d 个前缀匹配文件，将使用第一个: %s', ...
                        numel(listing), prefix);
                end
                filePath = fullfile(listing(1).folder, listing(1).name);
                return;
            end

            if ~isfile(path)
                error('LegacyLTEDataFile:FileNotFound', ...
                    '数据文件或目录不存在: %s', path);
            end
            filePath = path;

            if isempty(strtrim(prefix))
                [~, fileName, extension] = fileparts(filePath);
                if ~strcmpi(extension, '.bin')
                    error('LegacyLTEDataFile:UnsupportedPath', ...
                        '旧格式数据文件必须是 .bin 文件: %s', filePath);
                end
                prefix = lteio.LegacyLTEDataFile.inferPrefix(fileName);
            else
                prefix = strtrim(prefix);
            end
        end

        function prefix = inferPrefix(fileName)
            tokens = regexp(fileName, '_', 'split');
            knownKeys = {'fc', 'freq', 'frequency', 'fs', 'sr', ...
                'sample_rate', 'samplerate', 'tp', 'type', ...
                'datatype', 'data_type'};
            lowerTokens = cellfun(@lower, tokens, 'UniformOutput', false);
            keyIndex = find(ismember(lowerTokens, knownKeys), 1, 'first');
            if isempty(keyIndex) || keyIndex <= 1
                error('LegacyLTEDataFile:MissingPrefix', ...
                    ['无法从文件名推断前缀，请显式传入 prefix。' ...
                     ' 文件名: %s'], fileName);
            end
            prefix = strjoin(tokens(1:keyIndex-1), '_');
        end

        function [dateCode, recordId] = parseIndexedPrefix(prefix)
            tokens = regexp(prefix, '(\d{8})_(\d+)$', ...
                'tokens', 'once');
            if isempty(tokens)
                dateCode = '';
                recordId = '';
            else
                dateCode = tokens{1};
                recordId = tokens{2};
            end
        end

        function [metadata, keys, values] = parseMetadata(fileName, prefix)
            if ~startsWith(fileName, [prefix '_'])
                error('LegacyLTEDataFile:PrefixMismatch', ...
                    '文件名不以指定前缀 "%s_" 开头: %s', prefix, fileName);
            end

            suffix = fileName(numel(prefix) + 2:end);
            tokens = regexp(suffix, '_', 'split');
            if isempty(suffix) || mod(numel(tokens), 2) ~= 0
                error('LegacyLTEDataFile:InvalidMetadata', ...
                    ['前缀后的文件名必须由成对的键值组成: ' ...
                     '%s_key_value_...'], fileName);
            end

            keys = tokens(1:2:end);
            values = tokens(2:2:end);
            metadata = struct();
            for index = 1:numel(keys)
                key = strtrim(keys{index});
                if isempty(key)
                    error('LegacyLTEDataFile:InvalidMetadata', ...
                        '元数据键不能为空: %s', fileName);
                end
                field = matlab.lang.makeValidName(lower(key));
                if isfield(metadata, field)
                    error('LegacyLTEDataFile:DuplicateMetadataKey', ...
                        '文件名中出现重复元数据键 "%s": %s', ...
                        key, fileName);
                end
                metadata.(field) = values{index};
            end
        end

        function value = getMetadata(metadata, names)
            value = '';
            for index = 1:numel(names)
                field = matlab.lang.makeValidName(lower(names{index}));
                if isfield(metadata, field)
                    value = char(metadata.(field));
                    return;
                end
            end
        end

        function value = parseQuantity(textValue)
            if isempty(textValue)
                value = NaN;
                return;
            end

            tokens = regexp(lower(strtrim(char(textValue))), ...
                '^([+-]?(?:\d+(?:\.\d*)?|\.\d+))([a-z]*)$', ...
                'tokens', 'once');
            if isempty(tokens)
                error('LegacyLTEDataFile:InvalidQuantity', ...
                    '无法解析数值元数据: %s', char(textValue));
            end

            number = str2double(tokens{1});
            switch tokens{2}
                case {'g', 'ghz'}
                    scale = 1e9;
                case {'m', 'mhz'}
                    scale = 1e6;
                case {'k', 'khz'}
                    scale = 1e3;
                case {'', 'h', 'hz'}
                    scale = 1;
                otherwise
                    error('LegacyLTEDataFile:InvalidUnit', ...
                        '无法识别数值元数据单位: %s', tokens{2});
            end
            value = number * scale;
        end
    end
end
