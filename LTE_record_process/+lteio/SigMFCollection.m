classdef SigMFCollection < handle
%SIGMFCOLLECTION Reader for a SigMF collection descriptor.
%
%   obj = SigMFCollection(rootDir, collectionName)
%
% COLLECTIONNAME must not include a suffix. The constructor resolves:
%   rootDir/collectionName.sigmf-collection
%
% Each entry in core:streams is loaded as a SigMFDataFile object in
% obj.streams.

    properties (SetAccess = private)
        root_dir = ''
        collection_name = ''
        file_path = ''
        metadata = struct()
        collection = struct()
        stream_definitions = struct([])
        stream_names = {}
        streams
        stream_count = 0
    end

    methods
        function obj = SigMFCollection(rootDir, collectionName)
            if nargin < 2 || isempty(rootDir) || isempty(collectionName)
                error('SigMFCollection:MissingPath', ...
                    '必须指定根目录和不含后缀的 collection 文件名称。');
            end
            rootDir = char(rootDir);
            collectionName = char(collectionName);

            if ~isfolder(rootDir)
                error('SigMFCollection:RootNotFound', ...
                    'SigMF 根目录不存在: %s', rootDir);
            end
            [~, ~, extension] = fileparts(collectionName);
            if ~isempty(extension) || contains(collectionName, filesep) || ...
                    contains(collectionName, '/') || contains(collectionName, '\\')
                error('SigMFCollection:InvalidName', ...
                    'collectionName 必须是不含路径和后缀的名称: %s', ...
                    collectionName);
            end

            obj.root_dir = rootDir;
            obj.collection_name = collectionName;
            obj.file_path = fullfile(rootDir, ...
                [collectionName '.sigmf-collection']);
            obj.streams = lteio.SigMFDataFile.empty(0, 0);

            if ~isfile(obj.file_path)
                error('SigMFCollection:FileNotFound', ...
                    'collection 文件不存在: %s', obj.file_path);
            end

            obj.metadata = lteio.SigMFCollection.readJson(obj.file_path);
            obj.collection = lteio.SigMFCollection.getJsonField( ...
                obj.metadata, 'collection', struct());
            definitions = lteio.SigMFCollection.getJsonField( ...
                obj.collection, 'core:streams', struct([]));
            obj.stream_definitions = definitions;

            if isempty(definitions)
                obj.stream_names = {};
                obj.stream_count = 0;
                return;
            end

            obj.stream_count = numel(definitions);
            obj.stream_names = cell(obj.stream_count, 1);
            obj.streams = lteio.SigMFDataFile.empty(0, obj.stream_count);
            for k = 1:obj.stream_count
                streamName = lteio.SigMFCollection.toChar( ...
                    lteio.SigMFCollection.getJsonField(definitions(k), ...
                    'name', ''));
                if isempty(streamName)
                    error('SigMFCollection:InvalidStream', ...
                        '第 %d 个 stream 缺少 name 字段。', k);
                end

                % Current records use a suffix-free stream name. Accepting
                % the two SigMF suffixes here makes the collection reader
                % tolerant of older descriptors without changing its public
                % suffix-free interface.
                [~, baseName, extension] = fileparts(streamName);
                if any(strcmpi(extension, {'.sigmf-data', '.sigmf-meta'}))
                    streamName = baseName;
                end

                obj.stream_names{k} = streamName;
                obj.streams(k) = lteio.SigMFDataFile(rootDir, streamName);
            end
        end

        function stream = getStream(obj, indexOrName)
            %GETSTREAM Return a stream by one-based index or record name.
            if isnumeric(indexOrName)
                if ~isscalar(indexOrName) || indexOrName < 1 || ...
                        indexOrName > obj.stream_count || ...
                        indexOrName ~= floor(indexOrName)
                    error('SigMFCollection:InvalidStreamIndex', ...
                        'stream 索引必须在 1 到 %d 之间。', obj.stream_count);
                end
                stream = obj.streams(indexOrName);
                return;
            end

            name = char(indexOrName);
            index = find(strcmp(obj.stream_names, name), 1);
            if isempty(index)
                error('SigMFCollection:StreamNotFound', ...
                    '未找到 stream: %s', name);
            end
            stream = obj.streams(index);
        end

        function info = describe(obj)
            info = struct( ...
                'format', 'sigmf-collection', ...
                'root_dir', obj.root_dir, ...
                'collection_name', obj.collection_name, ...
                'file_path', obj.file_path, ...
                'stream_names', {obj.stream_names}, ...
                'stream_count', obj.stream_count);
        end
    end

    methods (Static, Access = private)
        function raw = readJson(path)
            try
                raw = jsondecode(fileread(path));
            catch err
                error('SigMFCollection:JsonReadError', ...
                    '无法读取 collection JSON 文件: %s\n%s', ...
                    path, err.message);
            end
        end

        function value = getJsonField(s, name, defaultValue)
            value = defaultValue;
            if ~isstruct(s)
                return;
            end

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
