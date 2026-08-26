classdef (Abstract) IQDataFile < handle
%IQDATAFILE Common interface for IQ data file readers.
%
% Concrete readers implement readAt according to their storage layout.
% The base class owns only common metadata, cursor operations, and a
% protected helper for the currently common interleaved-IQ layout.

    properties (SetAccess = protected)
        kind = 'recording'
        format = ''
        file_path = ''             % data file path; empty for a collection object
        data_exists = false
        data_type = ''             % MATLAB type, e.g. int16 or single
        datatype = ''              % source-format datatype, e.g. ci16_le
        datatype_info = struct()
        sample_rate = NaN           % Hz
        frequency = NaN             % Hz
        num_channels = 1
        sample_count = NaN
        data_bytes = NaN
    end

    properties
        % Zero-based index of the next sample returned by read().
        offset = 0
    end

    properties (Dependent, SetAccess = private)
        eof
        duration_seconds
        fc
        sr
    end

    methods
        function obj = IQDataFile()
            % Base constructor. Concrete subclasses initialize metadata.
        end

        function signal = read(obj, len, normalize)
            %READ Read from the current offset and advance that offset.
            if nargin < 2 || isempty(len)
                len = Inf;
            end
            if nargin < 3 || isempty(normalize)
                normalize = false;
            end

            signal = obj.readAt(obj.offset, len, normalize);
            obj.offset = obj.offset + numel(signal);
        end

        function newOffset = seek(obj, position, origin)
            %SEEK Set the current zero-based sample offset.
            % origin is 'bof' (default), 'cof', or 'eof'.
            obj.assertRecording();
            if nargin < 3 || isempty(origin)
                origin = 'bof';
            end
            origin = lower(char(origin));
            position = double(position);
            if ~isscalar(position) || ~isfinite(position) || ...
                    position ~= floor(position)
                error('IQDataFile:InvalidOffset', ...
                    '偏移必须是整数采样索引。');
            end

            switch origin
                case {'bof', 'begin', 'start'}
                    if position < 0
                        error('IQDataFile:InvalidOffset', ...
                            '相对于文件开头的偏移不能为负。');
                    end
                    newOffset = position;
                case {'cof', 'current'}
                    newOffset = obj.offset + position;
                case {'eof', 'end'}
                    newOffset = obj.sample_count + position;
                otherwise
                    error('IQDataFile:InvalidOrigin', ...
                        'origin 必须是 ''bof''、''cof'' 或 ''eof''。');
            end

            if newOffset < 0 || newOffset > obj.sample_count
                error('IQDataFile:OffsetOutOfRange', ...
                    '目标偏移 %.0f 不在 [0, %.0f] 范围内。', ...
                    newOffset, obj.sample_count);
            end
            obj.offset = newOffset;
        end

        function newOffset = skip(obj, count)
            %SKIP Move the current offset by COUNT samples.
            if nargin < 2
                count = 0;
            end
            newOffset = obj.seek(count, 'cof');
        end

        function reset(obj)
            %RESET Return to the first sample.
            obj.seek(0, 'bof');
        end

        function value = get.eof(obj)
            value = strcmp(obj.kind, 'recording') && ...
                isfinite(obj.sample_count) && obj.offset >= obj.sample_count;
        end

        function value = get.duration_seconds(obj)
            if isfinite(obj.sample_rate) && obj.sample_rate > 0 && ...
                    isfinite(obj.sample_count)
                value = obj.sample_count / obj.sample_rate;
            else
                value = NaN;
            end
        end

        function value = get.fc(obj)
            value = obj.frequency;
        end

        function value = get.sr(obj)
            value = obj.sample_rate;
        end

        function info = describe(obj)
            %DESCRIBE Return only the common metadata as a plain structure.
            info = struct( ...
                'kind', obj.kind, ...
                'format', obj.format, ...
                'file_path', obj.file_path, ...
                'data_type', obj.data_type, ...
                'datatype', obj.datatype, ...
                'sample_rate', obj.sample_rate, ...
                'frequency', obj.frequency, ...
                'sample_count', obj.sample_count, ...
                'offset', obj.offset, ...
                'num_channels', obj.num_channels, ...
                'duration_seconds', obj.duration_seconds);
        end
    end

    methods (Abstract)
        signal = readAt(obj, from, len, normalize)
    end

    methods (Static)
        function info = makeDatatypeInfo(dataType, isComplex)
            %MAKEDATATYPEINFO Normalize a SigMF or MATLAB data type.
            if nargin < 2 || isempty(isComplex)
                isComplex = [];
            end
            dataType = lower(strtrim(char(dataType)));
            if isempty(dataType)
                error('IQDataFile:InvalidDatatype', '数据类型不能为空。');
            end

            isSigMF = any(strcmp(dataType(1), {'c', 'r'}));
            if isempty(isComplex)
                if isSigMF
                    isComplex = dataType(1) == 'c';
                else
                    % Legacy GNU Radio files store interleaved I/Q.
                    isComplex = true;
                end
            end

            info = struct();
            info.name = dataType;
            info.is_complex = logical(isComplex);
            info.is_real = ~info.is_complex;
            if isSigMF
                body = dataType(2:end);
                if endsWith(body, '_le')
                    info.endianness = 'little';
                    body = body(1:end-3);
                    info.machine_format = 'ieee-le';
                elseif endsWith(body, '_be')
                    info.endianness = 'big';
                    body = body(1:end-3);
                    info.machine_format = 'ieee-be';
                else
                    info.endianness = 'native';
                    info.machine_format = 'native';
                end
            else
                body = dataType;
                info.endianness = 'native';
                info.machine_format = 'native';
            end

            switch body
                case {'i8', 'int8'}
                    info.matlab_type = 'int8';
                    info.bits_per_scalar = 8;
                    info.is_integer = true;
                    info.is_unsigned = false;
                case {'u8', 'uint8'}
                    info.matlab_type = 'uint8';
                    info.bits_per_scalar = 8;
                    info.is_integer = true;
                    info.is_unsigned = true;
                case {'i16', 'int16'}
                    info.matlab_type = 'int16';
                    info.bits_per_scalar = 16;
                    info.is_integer = true;
                    info.is_unsigned = false;
                case {'u16', 'uint16'}
                    info.matlab_type = 'uint16';
                    info.bits_per_scalar = 16;
                    info.is_integer = true;
                    info.is_unsigned = true;
                case {'i32', 'int32'}
                    info.matlab_type = 'int32';
                    info.bits_per_scalar = 32;
                    info.is_integer = true;
                    info.is_unsigned = false;
                case {'u32', 'uint32'}
                    info.matlab_type = 'uint32';
                    info.bits_per_scalar = 32;
                    info.is_integer = true;
                    info.is_unsigned = true;
                case {'i64', 'int64'}
                    info.matlab_type = 'int64';
                    info.bits_per_scalar = 64;
                    info.is_integer = true;
                    info.is_unsigned = false;
                case {'u64', 'uint64'}
                    info.matlab_type = 'uint64';
                    info.bits_per_scalar = 64;
                    info.is_integer = true;
                    info.is_unsigned = true;
                case {'f32', 'single', 'float', 'float32'}
                    info.matlab_type = 'single';
                    info.bits_per_scalar = 32;
                    info.is_integer = false;
                    info.is_unsigned = false;
                case {'f64', 'double', 'float64'}
                    info.matlab_type = 'double';
                    info.bits_per_scalar = 64;
                    info.is_integer = false;
                    info.is_unsigned = false;
                otherwise
                    error('IQDataFile:UnsupportedDatatype', ...
                        '不支持的数据类型: %s', dataType);
            end

            info.bytes_per_scalar = info.bits_per_scalar / 8;
            info.components_per_sample = 1 + double(info.is_complex);
            info.bytes_per_sample = ...
                info.components_per_sample * info.bytes_per_scalar;
        end
    end

    methods (Access = protected)
        function assertRecording(obj)
            if ~strcmp(obj.kind, 'recording')
                error('IQDataFile:CollectionRead', ...
                    'collection 本身不能直接读取，请使用对应的 stream 对象。');
            end
        end

        function value = validateIndex(~, value, name)
            value = double(value);
            if ~isscalar(value) || ~isfinite(value) || value < 0 || ...
                    value ~= floor(value)
                error('IQDataFile:InvalidIndex', ...
                    '%s 必须是非负整数。', name);
            end
        end

        function value = canUseMemmap(~, info)
            [~, ~, endian] = computer;
            hostIsLittle = strcmpi(endian, 'L');
            dataIsNative = strcmp(info.endianness, 'native');
            dataIsLittle = strcmp(info.endianness, 'little');
            dataIsBig = strcmp(info.endianness, 'big');
            value = dataIsNative || ...
                (hostIsLittle && dataIsLittle) || ...
                (~hostIsLittle && dataIsBig);
        end
    end
end
