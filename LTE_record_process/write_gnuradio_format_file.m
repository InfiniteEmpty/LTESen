function write_gnuradio_format_file(file_path, signal)
%WRITE_GNURADIO_FORMAT_FILE 将复序列信号以 GNURadio 规定的格式写入 .bin 文件
%   file_path: 保存 .bin 文件的路径
%   signal: 复序列信号 (列向量)

% 转换为单精度浮点数
signal_single = single(signal(:));

% 交错实部与虚部: [I0, Q0, I1, Q1, I2, Q2, ...]
n = length(signal_single);
interleaved = zeros(2 * n, 1, 'single');
interleaved(1:2:end) = real(signal_single);
interleaved(2:2:end) = imag(signal_single);

% 一次性写入文件
fid = fopen(file_path, 'wb');
fwrite(fid, interleaved, 'float32');
fclose(fid);

end

