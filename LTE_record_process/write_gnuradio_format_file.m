function write_gnuradio_format_file(file_path, signal)
%WRITE_GNURADIO_FORMAT_FILE 将复序列信号以 GNURadio 规定的格式写入 .bin 文件
%   file_path: 保存 .bin 文件的路径
%   signal: 复序列信号

% 转换为单精度浮点数 (GNU Radio期望32位浮点数)
signal_float = single(signal);

% 将复数数据写入文件: 交错存储实部和虚部
% 格式: I0, Q0, I1, Q1, I2, Q2, ...
fid = fopen(file_path, 'wb');
for i = 1:length(signal_float)
    fwrite(fid, real(signal_float(i)), 'float');
    fwrite(fid, imag(signal_float(i)), 'float');
end
fclose(fid);

end

