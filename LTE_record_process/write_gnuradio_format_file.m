function write_gnuradio_format_file(file_path, signal, writeType)
%WRITE_GNURADIO_FORMAT_FILE 将复序列信号以 GNURadio 规定的格式写入 .bin 文件
%   file_path: 保存 .bin 文件的路径
%   signal: 复序列信号 (列向量)
%   writeType: 数据类型

% 交错实部与虚部: [I0, Q0, I1, Q1, I2, Q2, ...]
n = length(signal);
interleaved = zeros(2 * n, 1);
interleaved(1:2:end) = real(signal);
interleaved(2:2:end) = imag(signal);

% 一次性写入文件
fid = fopen(file_path, 'wb');
fwrite(fid, interleaved, writeType);
fclose(fid);

end

