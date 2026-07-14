function signal = read_gnuradio_format_file(filePath, readType, from, len, normalize)
%READ_GNURADIO_FORMAT_FILE 读取 GNURadio File Sink 生成的 .bin 文件中指定位
% 置的数据，转换为复序列输出
%
% 输入参数：
%   filePath  - .bin 文件的路径 (字符串)
%   readType  - 数据类型 (字符串): 'int8'|'uint8'|'int16'|'uint16'|...
%   from      - 读取起点，采样点偏移 (可选, 默认 0)
%   len       - 读取的采样点数 (可选, 默认 Inf = 读取全部)
%   normalize - 是否归一化到 [-1, 1] (可选, 默认 false)
%               对于整数类型 (int16/int8/int32 等)，
%               转换为 double 并除以 2^(bits-1)；
%               对于无符号类型 (uint8 等)，先减去中值再归一化。
%               浮点类型 (single/double) 不做缩放，仅转为 double。
%
% 输出参数：
%   signal    - 复序列信号 (double 类型)
%
% 示例：
%   % 读取 int16 文件，从第 0 点开始，读 307200 点，并归一化
%   signal = read_gnuradio_format_file('data.bin', 'int16', 0, 307200, true);
%
%   % 读取全部 float32 文件
%   signal = read_gnuradio_format_file('data.bin', 'single');

% ===== 参数默认值 =====
if nargin < 3 || isempty(from),      from = 0;       end
if nargin < 4 || isempty(len),       len = Inf;      end
if nargin < 5 || isempty(normalize), normalize = false; end

% ===== 读取文件 =====
stepLen = 2 * type_len(readType);

fid = fopen(filePath, 'rb');
if fid == -1
    error('read_gnuradio_format_file:FileOpen', ...
          '无法打开文件: %s', filePath);
end

if fseek(fid, stepLen * from, 'bof') == 0
    ravel_signal = fread(fid, 2 * len, ['*' readType]);
    % 交错拆分: [I0, Q0, I1, Q1, ...] → I + 1j*Q
    signal = double(ravel_signal(1:2:end)) + 1j * double(ravel_signal(2:2:end));
else
    fclose(fid);
    error('read_gnuradio_format_file:FseekError', ...
          '文件索引错误: offset=%d, file=%s', from, filePath);
end
fclose(fid);

% ===== 归一化 =====
if normalize && ~isempty(signal)
    nBytes = type_len(readType);

    % 判断是否为整数类型 (排除 single/double 等浮点)
    isFloat = any(strcmpi(readType, {'single', 'float', 'float32', 'double', 'float64'}));

    if ~isFloat
        % scale = 2^(bits-1), 其中 bits = nBytes * 8
        scale = 2^(nBytes * 8 - 1);

        % 无符号类型 (uint8/uint16/uint32) 需先减去中值
        if startsWith(lower(readType), 'u')
            signal = (signal - scale - 1j*scale) / scale;
        else
            signal = signal / scale;
        end
    end
    % 浮点类型不做缩放
end

end
