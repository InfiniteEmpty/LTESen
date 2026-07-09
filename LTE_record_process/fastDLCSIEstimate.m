function [CSI_G1, CSI_G2, K_idx_G1, K_idx_G2] = fastDLCSIEstimate(enb, rxgrid_sf)
% FASTDLCSIESTIMATE 直接提取同子载波的 LTE CRS，拼接成 CSI 矩阵
% 
% 返回值:
% CSI_G1: 第一、三列 CRS 组成的信道矩阵，大小 [N_crs_freq, 2, nRx, nTx]
% CSI_G2: 第二、四列 CRS 组成的信道矩阵，大小 [N_crs_freq, 2, nRx, nTx]
% K_idx_G1, K_idx_G2: 对应的子载波物理索引，大小 [N_crs_freq, nTx]

[K, L, nRx] = size(rxgrid_sf);
nTx = enb.CellRefP;

% 每个 PRB 在频域上包含 2 个 CRS 子载波
N_crs_freq = enb.NDLRB * 2; 

% 预分配空间（相比动态扩容大幅提升速度）
CSI_G1 = zeros(N_crs_freq, 2, nRx, nTx);
CSI_G2 = zeros(N_crs_freq, 2, nRx, nTx);
K_idx_G1 = zeros(N_crs_freq, nTx);
K_idx_G2 = zeros(N_crs_freq, nTx);

for tx = 1:nTx
    % 获取当前 Tx 天线端口的 CRS 索引和复数符号
    crsIdx = lteCellRSIndices(enb, tx-1);
    crsSym = lteCellRS(enb, tx-1);
    
    if isempty(crsIdx)
        continue;
    end
    
    % 拆分为二维网格索引
    [k_idx, l_idx, ~] = ind2sub([K, L, nTx], crsIdx);
    
    % 获取该端口存在 CRS 的所有符号列 (Normal CP 下为 4 列)
    % 比如 Port 0 为符号索引 1, 5, 8, 12
    unique_l = unique(l_idx);
    
    % --- 处理 Group 1 (第一列与第三列) ---
    mask1 = (l_idx == unique_l(1));
    mask3 = (l_idx == unique_l(3));
    
    k1 = k_idx(mask1); 
    K_idx_G1(:, tx) = k1; % 记录组 1 的子载波索引
    
    crs1 = crsSym(mask1);
    crs3 = crsSym(mask3);
    
    % --- 处理 Group 2 (第二列与第四列) ---
    mask2 = (l_idx == unique_l(2));
    mask4 = (l_idx == unique_l(4));
    
    k2 = k_idx(mask2);
    K_idx_G2(:, tx) = k2; % 记录组 2 的子载波索引
    
    crs2 = crsSym(mask2);
    crs4 = crsSym(mask4);
    
    % 遍历接收天线，利用矩阵索引直接计算 LS 估计并拼接
    for rx = 1:nRx
        % --- 提取 Group 1 ---
        % y1 和 y3 均直接切片提取相同子载波位置的接收信号
        y1 = rxgrid_sf(k1, unique_l(1), rx);
        y3 = rxgrid_sf(k1, unique_l(3), rx);
        
        CSI_G1(:, 1, rx, tx) = y1 ./ crs1;
        CSI_G1(:, 2, rx, tx) = y3 ./ crs3;
        
        % --- 提取 Group 2 ---
        y2 = rxgrid_sf(k2, unique_l(2), rx);
        y4 = rxgrid_sf(k2, unique_l(4), rx);
        
        CSI_G2(:, 1, rx, tx) = y2 ./ crs2;
        CSI_G2(:, 2, rx, tx) = y4 ./ crs4;
    end
end

end
