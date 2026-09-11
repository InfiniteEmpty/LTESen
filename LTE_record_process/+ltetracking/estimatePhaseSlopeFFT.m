function d_idx = estimatePhaseSlopeFFT(signal)
%ESTIMATEPHASESLOPEFFT 利用 FFT 与抛物线插值极速搜索高精度相位斜率 (支持任意张量)
% 
% 参数:
% signal - 任意维度张量 [K x D2 x D3 x ...]。
%          函数将沿着第1个维度 (长度为K) 独立进行运算，保留高维结构。
%
% 返回:
% d_idx  - 对应每个子维度的相位斜率偏移量。
%          输出尺寸为 [1 x D2 x D3 x ...]

% 获取输入张量的尺寸信息
sz = size(signal);
K = sz(1);

% --- 第一步：补零扩展，提升 FFT 基础网格分辨率 ---
N_pad = max(1024, 2^nextpow2(K * 4)); 

% --- 第二步：计算 FFT 能量谱 ---
% 沿第1个维度 (子载波/时间维度) 作 FFT
X = fft(signal, N_pad, 1); 

% 沿第1维度计算能量（移除原先的 sum，以支持高维独立运算）
magX = abs(X).^2; 

% 【核心技巧】将高维张量展平为 2D 矩阵 [N_pad, D]，方便进行向量化寻峰
D = prod(sz(2:end)); % 计算除第1维度外，其余所有维度的元素总数
magX_2D = reshape(magX, N_pad, D);

% --- 第三步：寻找离散谱峰值 ---
% 沿列方向寻找最大值，y0 和 k_max 的尺寸均为 [1 x D]
[y0, k_max] = max(magX_2D, [], 1);

% 获取左右相邻点的行索引，并处理周期性边界条件
k_minus = k_max - 1;
k_minus(k_minus < 1) = N_pad; % 触及左边界则折返到右边

k_plus = k_max + 1;
k_plus(k_plus > N_pad) = 1;   % 触及右边界则折返到左边

% 转换为 MATLAB 的线性索引 (Linear Indexing)，极速提取左右两边的值
col_idx = 1:D;
idx_minus = k_minus + (col_idx - 1) * N_pad;
idx_plus  = k_plus  + (col_idx - 1) * N_pad;

y_minus = magX_2D(idx_minus);
y_plus  = magX_2D(idx_plus);

% --- 第四步：抛物线插值计算次网格偏移 ---
% 计算分母，并防止除以 0 的情况 (例如全 0 信号)
denom = y_minus - 2 * y0 + y_plus;
denom(denom == 0) = eps; 

% delta 范围在 [-0.5, 0.5] 之间 (注意使用点除 ./)
delta = 0.5 * (y_minus - y_plus) ./ denom;

% 连续域的峰值位置
k_peak = k_max + delta;

% --- 第五步：将 FFT Bin 索引映射回物理相位斜率 ---
% 转换为 0-based 索引
k_idx = k_peak - 1;

% 频率折叠处理 (将区间 [N_pad/2, N_pad-1] 映射到负频率)
fold_mask = k_idx > N_pad / 2;
k_idx(fold_mask) = k_idx(fold_mask) - N_pad;

% 在原先坐标轴上的偏移量，尺寸仍为 [1 x D]
d_idx_2D = k_idx / N_pad * K;

% --- 第六步：重塑回张量形状 ---
% 将输出从 [1 x D] 还原回 [1 x D2 x D3 x ...]
out_sz = sz;
out_sz(1) = 1; 
d_idx = reshape(d_idx_2D, out_sz);

end
