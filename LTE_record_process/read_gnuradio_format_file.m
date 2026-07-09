function signal = read_gnuradio_format_file(filePath, readType, from, len)
%READ_GNURADIO_FORMAT_FILE 读取 GNURadio File Sink 生成的 .bin 文件中指定位
% 置的数据，转换为复序列输出
% 输入参数：
%   filePath: .bin 文件的路径
%   readType: 数据类型
%   from: 读取起点
%   len: 读取长度
% 输出参数：
%   signal: 复序列信号

% 步长（两个类型为 readType 的数据）
stepLen = 2 * type_len(readType);

% 读取位置默认值
if ~exist('from', 'var')
    from = 0;
end
if ~exist('len', 'var')
    len = Inf;
end

fid = fopen(filePath, 'rb');
if fseek(fid, stepLen*from, 'bof') == 0
    ravel_signal = fread(fid, 2*len, readType);
    signal = ravel_signal(1:2:end) + ravel_signal(2:2:end)*1i;
else
    fprintf("错误的文件索引");
    signal = [];
end
fclose(fid);

end

