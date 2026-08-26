function [root_dir, record_name] = autoLoadLTEFile(base_dir, prefix, date_code, id_code)
%AUTOLOADLTEFILE Locate one of the supported LTE recording formats.
%
%   [root_dir, record_name] = autoLoadLTEFile(date_code, prefix, id_code, is_ca)
%
% The returned record_name never contains a file suffix.  The caller can
% use it with the corresponding loader:
%   LegacyLTEDataFile(fullfile(root_dir, [record_name '.bin']))
%   SigMFDataFile(root_dir, record_name)
%   SigMFCollection(root_dir, record_name)
%
% For a non-CA recording, an exact SigMF data/meta pair is preferred.  If
% it is not present, the function falls back to the legacy .bin format.

    base_dir = char(base_dir);
    prefix = char(prefix);
    date_code = normalizeCode(date_code, '日期', 8);
    id_code = normalizeCode(id_code, '编号', []);

    root_dir = fullfile(base_dir, ['LTE_' date_code]);
    if ~isfolder(root_dir)
        error('autoLoadLTEFile:DirNotFound', ...
            '数据目录不存在: %s', root_dir);
    end

    % Collection names intentionally have a separate namespace.
    record_name = [prefix '_' date_code '_' toSixDigits(id_code)];
    collection_path = fullfile(root_dir, [record_name '.sigmf-collection']);
    if isfile(collection_path)
        return;
    end

    % Current single-channel SigMF recordings use six-digit IDs.
    record_name = [prefix '_' date_code '_' toSixDigits(id_code)];
    data_path = fullfile(root_dir, [record_name '.sigmf-data']);
    meta_path = fullfile(root_dir, [record_name '.sigmf-meta']);
    if isfile(data_path) && isfile(meta_path)
        return;
    end
    if isfile(data_path) || isfile(meta_path)
        error('autoLoadLTEFile:IncompleteSigMFPair', ...
            'SigMF 数据文件和元数据文件必须成对存在: %s / %s', ...
            data_path, meta_path);
    end

    % Legacy recordings use four-digit IDs and include acquisition
    % parameters in the filename.  Return the complete basename so that
    % the data type and other filename fields remain available to the
    % LegacyLTEDataFile constructor.
    legacy_id = toFourDigits(id_code);
    pattern = fullfile(root_dir, ...
        [prefix '_' date_code '_' legacy_id '_fc_*.bin']);
    listing = dir(pattern);
    if isempty(listing)
        error('autoLoadLTEFile:FileNotFound', ...
            ['未找到匹配文件。\n' ...
             '  SigMF 基名: %s\n' ...
             '  BIN 搜索模式: %s'], record_name, pattern);
    end

    if numel(listing) > 1
        warning('autoLoadLTEFile:MultipleMatches', ...
            '匹配到 %d 个旧 BIN 文件，将使用第一个: %s', ...
            numel(listing), pattern);
    end

    [~, record_name] = fileparts(listing(1).name);
end

function code = normalizeCode(value, label, requiredLength)
    if isnumeric(value)
        if ~isscalar(value) || ~isfinite(value) || value < 0 || value ~= fix(value)
            error('autoLoadLTEFile:InvalidInput', ...
                '%s必须是非负整数。', label);
        end
        code = sprintf('%.0f', value);
    else
        code = strtrim(char(value));
    end

    if isempty(code) || any(~isstrprop(code, 'digit'))
        error('autoLoadLTEFile:InvalidInput', ...
            '%s必须只包含数字。', label);
    end
    if ~isempty(requiredLength) && numel(code) ~= requiredLength
        error('autoLoadLTEFile:InvalidInput', ...
            '%s必须是 %d 位数字。', label, requiredLength);
    end
end

function code = toSixDigits(id_code)
    id_number = str2double(id_code);
    if ~isfinite(id_number) || id_number < 0 || id_number > 999999
        error('autoLoadLTEFile:InvalidInput', '编号超出六位编号范围。');
    end
    code = sprintf('%06.0f', id_number);
end

function code = toFourDigits(id_code)
    id_number = str2double(id_code);
    if ~isfinite(id_number) || id_number < 0 || id_number > 9999
        error('autoLoadLTEFile:InvalidInput', '旧 BIN 编号超出四位编号范围。');
    end
    code = sprintf('%04.0f', id_number);
end
