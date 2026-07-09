function byteLength = type_len(dataType)
%TYPE_LEN 输入数据类型名称，输出该数据类型占用的字节数
% 输入参数：
%   dataType: 数据类型（字符串）
% 输出参数：
%   byteLength: 数据类型占用的字节数

switch dataType
    case {'int8', 'uint8', 'logical'}
        byteLength = 1;
    case {'int16', 'uint16'}
        byteLength = 2;
    case {'int32', 'uint32', 'single'}
        byteLength = 4;
    case {'int64', 'uint64', 'double'}
        byteLength = 8;
    case 'char'
        byteLength = 2;
    otherwise
        error('不支持的数据类型: %s', dataType);
end

end
