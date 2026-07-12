function [file_path, fc, sr] = autoLoadLTEFile(date_str, id_str, base_dir)
%AUTOLOADLTEFILE  根据录制日期和编号自动匹配LTE数据文件，并解析载波频率与采样率
%
% 文件命名规范（必须严格遵守）:
%   LTE_fc_{freq}M_fs_{srate}k_{date}_{id}.bin
%
% 存放路径规范:
%   {base_dir}/LTE_{date}/LTE_fc_{freq}M_fs_{srate}k_{date}_{id}.bin
%
% Inputs:
%   date_str  - 录制日期，字符串或数值均可，如 '20260709' 或 20260709
%   id_str    - 文件唯一编号，字符串或数值均可，如 '0004' 或 4
%   base_dir  - 数据根目录（可选），默认为 'experiment_data'
%
% Outputs:
%   file_path - 匹配到的完整文件路径（字符串）
%   fc        - 载波频率 (Hz)，数值标量
%   sr        - 采样率 (Hz)，数值标量
%
% Example:
%   [fp, fc, sr] = autoLoadLTEFile('20260709', '0004');
%   % 自动找到 experiment_data/LTE_20260709/LTE_fc_1850M_fs_30720k_20260709_0004.bin
%   % fc = 1.85e9, sr = 3.072e7

    % ===== 参数默认值处理 =====
    if nargin < 3 || isempty(base_dir)
        base_dir = 'experiment_data';
    end

    % ===== 输入归一化：统一转为字符串 =====
    if isnumeric(date_str)
        date_str = num2str(date_str);
    end
    if isnumeric(id_str)
        id_str = num2str(id_str, '%04d');  % 确保 4 位补零
    end
    date_str = char(date_str);
    id_str   = char(id_str);

    % ===== 构建搜索目录和通配模式 =====
    search_dir = fullfile(base_dir, ['LTE_' date_str]);

    if ~isfolder(search_dir)
        error('autoLoadLTEFile:DirNotFound', ...
              '数据目录不存在: %s', search_dir);
    end

    % 通配模式：日期和编号精确匹配，频率和采样率用通配符
    pattern = fullfile(search_dir, ...
        ['LTE_fc_*M_fs_*k_' date_str '_' id_str '.bin']);

    % ===== 文件搜索 =====
    listing = dir(pattern);

    if isempty(listing)
        error('autoLoadLTEFile:FileNotFound', ...
              ['未找到匹配文件。\n' ...
               '  搜索模式: %s\n' ...
               '  请检查日期 ''%s'' 与编号 ''%s'' 是否正确，或文件是否存在于指定目录。'], ...
              pattern, date_str, id_str);
    end

    if length(listing) > 1
        warning('autoLoadLTEFile:MultipleMatches', ...
                ['匹配到 %d 个文件，将使用第一个:\n' ...
                 '  搜索模式: %s'], ...
                length(listing), pattern);
        for k = 1:length(listing)
            fprintf('    [%d] %s\n', k, listing(k).name);
        end
    end

    % 取第一个匹配结果
    filename = listing(1).name;
    file_path = fullfile(search_dir, filename);

    % ===== 从文件名解析 fc 和 sr =====
    % 文件名格式: LTE_fc_{freq}M_fs_{srate}k_{date}_{id}.bin
    tokens = regexp(filename, ...
        '^LTE_fc_(\d+)M_fs_(\d+)k_(\d{8})_(\d+)\.bin$', ...
        'tokens');

    if isempty(tokens)
        error('autoLoadLTEFile:ParseError', ...
              ['文件名格式不符合预期规范，无法解析:\n' ...
               '  文件名: %s\n' ...
               '  期望格式: LTE_fc_{freq}M_fs_{srate}k_{date}_{id}.bin'], ...
              filename);
    end

    t = tokens{1};
    fc_val = str2double(t{1});   % 载波频率，单位 MHz
    sr_val = str2double(t{2});   % 采样率，单位 kHz
    % t{3} 是日期，t{4} 是编号（已验证匹配，无需再取）

    % 转换为 Hz
    fc = fc_val * 1e6;   % MHz → Hz
    sr = sr_val * 1e3;   % kHz → Hz

    % ===== 输出汇总信息 =====
    fprintf('===== LTE 文件自动加载 =====\n');
    fprintf('  日期:    %s\n', date_str);
    fprintf('  编号:    %s\n', id_str);
    fprintf('  文件:    %s\n', file_path);
    fprintf('  载波频率: %.2f MHz  (%.0f Hz)\n', fc/1e6, fc);
    fprintf('  采样率:   %.3f MHz  (%.0f Hz)\n', sr/1e6, sr);
    fprintf('==============================\n');

end
