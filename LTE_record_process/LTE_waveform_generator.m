%%
% LTE_waveform_generator.m
% =========================================================================
% LTE 下行波形生成器 —— 用于 SDR 平台验证小区干扰
% =========================================================================

clear; clc; close all;

%% ====== 1. 参数设置 ======
NCellID      = 18;             % 物理小区 ID (0~503)
NDLRB        = 100;            % 下行 RB 数: 6 / 15 / 25 / 50 / 75 / 100
CellRefP     = 1;              % 天线端口数: 1, 2, 4
DuplexMode   = 'FDD';          % 双工模式: 'FDD' | 'TDD'
CyclicPrefix = 'Normal';       % CP 类型

% --- Payload 控制 ---
payload_ratio = 0.0;           % PDSCH 功率比例 (0.0~1.0, 0=不发送PDSCH数据)
pdsch_rbg_density = 0.0;       % PDSCH 频域稀疏度 (0.0~1.0, 0.5=隔一个RBG分配一个)
pdsch_power_boost_dB = 0;      % PDSCH 相对于 CRS 的功率偏置 (dB)
pdsch_modulation = 'QPSK';     % 'QPSK' | '16QAM' | '64QAM' | '256QAM'

% --- 输出控制 ---
amplitude    = 0.8;            % 整体缩放因子 (防止削峰)
fc_tx        = 1850;           
output_dir   = 'experiment_data/generated_waveforms'; 

%% ====== 2. 基础配置 ======
enb.NDLRB          = NDLRB;
enb.NCellID        = NCellID;
enb.CellRefP       = CellRefP;
enb.DuplexMode     = DuplexMode;
enb.CyclicPrefix   = CyclicPrefix;
enb.NFrame         = 0;

% 动态设定控制域大小 (CFI)
if NDLRB <= 10, enb.CFI = 3; else, enb.CFI = 2; end
enb.Ng             = 'Sixth'; 
enb.PHICHDuration  = 'Normal';

ofdmInfo = lteOFDMInfo(enb);
sr = ofdmInfo.SamplingRate;

fprintf('\n========== LTE Waveform Generator ==========\n');
fprintf('Bandwidth: %d RB (%.2f MHz), Sampling: %.3f MHz\n', NDLRB, sr/1e6, sr/1e6);
fprintf('Payload: PwrRatio=%.1f, Boost=%+d dB, RBG Density=%.0f%%\n', ...
    payload_ratio, pdsch_power_boost_dB, pdsch_rbg_density*100);

%% ====== 3. PDSCH / PDCCH 分配策略 ======
% --- PDSCH 配置 ---
if CellRefP == 1
    pdsch.TxScheme = 'Port0';     pdsch.NLayers = 1;
else
    pdsch.TxScheme = 'TxDiversity'; pdsch.NLayers = CellRefP;
end
pdsch.Modulation = {pdsch_modulation};
pdsch.RNTI       = 1;
pdsch.CSIMode    = 'PUCCH 1-1';
pdsch.CSIRefP    = CellRefP;
pdsch.NTxAnts    = CellRefP;

% --- RBG 计算与稀疏分配 ---
if NDLRB <= 10, P_rbg = 1; elseif NDLRB <= 26, P_rbg = 2; elseif NDLRB <= 63, P_rbg = 3; else, P_rbg = 4; end
nRBG = ceil(NDLRB / P_rbg);

nAllocRBG = round(pdsch_rbg_density * nRBG); 
allocPattern = false(1, nRBG);
if nAllocRBG > 0
    selectedIdx = round(linspace(1, nRBG, nAllocRBG));
    allocPattern(selectedIdx) = true;
end

rbgBitmap = repmat('0', 1, nRBG);
rbgBitmap(allocPattern) = '1';

allocPRBs = [];
for i = find(allocPattern)
    rbStart = (i-1) * P_rbg;
    allocPRBs = [allocPRBs, rbStart : min(i * P_rbg - 1, NDLRB - 1)]; 
end
pdsch.PRBSet = allocPRBs.';

fprintf('DCI Type 0: Allocated %d/%d RBGs (%d PRBs)\n', nAllocRBG, nRBG, length(allocPRBs));

% --- PDCCH 配置 ---
pdcchConfig.RNTI = 1;
pdcchConfig.PDCCHFormat = 0;
dciConfig.DCIFormat = 'Format1';
dciConfig.AllocationType = 0;
dciConfig.Allocation = rbgBitmap; 

%% ====== 4. 逐子帧生成资源网格 ======
fprintf('\n--- Generating 10 subframes ---\n');
symsPerSubframe = length(ofdmInfo.CyclicPrefixLengths);
txGrid = zeros(NDLRB * 12, 10 * symsPerSubframe, CellRefP);

for sf = 0:9
    enb.NSubframe = sf;
    sfGrid = lteResourceGrid(enb); 

    % 填入 CRS, PSS, SSS
    for p = 0:(CellRefP-1)
        sfGrid(lteCellRSIndices(enb, p)) = lteCellRS(enb, p);
    end
    if any(sf == [0 5])
        sfGrid = safeGridAssign(sfGrid, ltePSSIndices(enb), ltePSS(enb)); 
        sfGrid = safeGridAssign(sfGrid, lteSSSIndices(enb), lteSSS(enb)); 
    end
    
    % 填入 PBCH
    if sf == 0
        pbchSym = ltePBCH(enb, lteBCH(enb, lteMIB(enb)));
        pbchIdx = ltePBCHIndices(enb);
        % 【修复】PBCH 周期为40ms，截取当前帧所需的 240 个符号防止溢出
        frameOffset = mod(enb.NFrame, 4) * 240;
        pbchSym = pbchSym(frameOffset + (1:240), :);
        sfGrid = safeGridAssign(sfGrid, pbchIdx, pbchSym); 
    end

    % 填入 PDCCH
    % 【修复】第二个返回值 (dciBits) 才是用于编码的真正数值流
    [~, dciBits] = lteDCI(enb, dciConfig);
    if iscell(dciBits), dciBits = dciBits{1}; end 
    pdcchCW = lteDCIEncode(pdcchConfig, dciBits);
    pdcchSym = ltePDCCH(enb, pdcchCW);
    pdcchIdx = ltePDCCHIndices(enb);
    
    % 【修复】动态截断 PDCCH 资源池中未使用的候选 RE
    if ~iscell(pdcchIdx) && ~iscell(pdcchSym)
        pdcchIdx = pdcchIdx(1:size(pdcchSym,1), :);
    end
    sfGrid = safeGridAssign(sfGrid, pdcchIdx, pdcchSym);

    % 填入 PDSCH
    totalScale = sqrt(payload_ratio) * (10^(pdsch_power_boost_dB/20));
    
    if (totalScale > 0) && ~isempty(pdsch.PRBSet)
        [pdschIdx, pdschInfo] = ltePDSCHIndices(enb, pdsch, pdsch.PRBSet);
        if pdschInfo.G > 0 
            codedBits = randi([0 1], pdschInfo.G, 1);
            pdschCW = ltePDSCH(enb, pdsch, codedBits);
            
            % 功率缩放
            if iscell(pdschCW)
                for ap = 1:length(pdschCW), pdschCW{ap} = pdschCW{ap} * totalScale; end
            else
                pdschCW = pdschCW * totalScale;
            end
            
            sfGrid = safeGridAssign(sfGrid, pdschIdx, pdschCW);
        end
    end

    txGrid(:, (sf * symsPerSubframe + 1) : ((sf+1) * symsPerSubframe), :) = sfGrid;
    fprintf('  SF%2d: Filled %d REs\n', sf, nnz(sfGrid));
end

%% ====== 5. 调制与导出 ======
fprintf('\n--- OFDM Modulation & Export ---\n');

txWaveform = lteOFDMModulate(enb, txGrid);

maxAbs = max(abs(txWaveform(:)));
txWaveform = (txWaveform / maxAbs) * amplitude;
if max(abs(txWaveform(:))) > 1.0
    txWaveform = max(min(txWaveform, 1.0), -1.0); 
end

if ~exist(output_dir, 'dir'), mkdir(output_dir); end
output_name = sprintf('LTE_fc_%.0fM_fs_%.0fk_NCellID_%03d_Density_%03d.bin', ...
    fc_tx, sr/1e3, NCellID, round(pdsch_rbg_density*100));

txWaveform = repmat(txWaveform, [200 1]);

for p = 1:size(txWaveform, 2)
    filename = fullfile(output_dir, strrep(output_name, '.bin', sprintf('_port%d.bin', p-1)));
    write_gnuradio_format_file(filename, txWaveform(:, p), 'double');
    fprintf('Saved: %s (RMS=%.3f, Peak=%.3f)\n', filename, rms(txWaveform(:, p)), max(abs(txWaveform(:, p))));
end

%% ====== 6. 可视化 (资源网格) ======
figure('Name', 'LTE Downlink Resource Grid', 'Position', [200, 200, 1000, 400]);
imagesc(1:size(txGrid,2), 1:size(txGrid,1), 20*log10(abs(txGrid(:,:,1)) + 1e-6));
xlabel('OFDM Symbol Index'); ylabel('Subcarrier Index');
title(sprintf('Resource Grid (Port 0) - %d RB, RBG Density %.0f%%', NDLRB, pdsch_rbg_density*100));
colorbar; colormap('jet'); clim([-40 5]); axis xy;

%% ====== 辅助函数 ======
function sfGrid = safeGridAssign(sfGrid, idx, sym)
    % 适配单/多天线端口的资源映射，统一使用 numel 进行平铺校验
    if iscell(idx) && iscell(sym)
        for p = 1:min(length(idx), length(sym)), sfGrid(idx{p}) = sym{p}; end
    elseif iscell(idx) && ~iscell(sym)
        allIdx = cell2mat(cellfun(@(c) c(:), idx(:), 'UniformOutput', false));
        if numel(allIdx) == numel(sym), sfGrid(allIdx) = sym(:); end
    elseif ~iscell(idx) && iscell(sym)
        allSym = cell2mat(cellfun(@(c) c(:), sym(:), 'UniformOutput', false));
        if numel(idx) == numel(allSym), sfGrid(idx(:)) = allSym; end
    else
        if numel(idx) == numel(sym)
            sfGrid(idx(:)) = sym(:);  % 【修复】直接一维展平赋值，防止行/列向量形状差异报错
        else
            warning('safeGridAssign: Length mismatch (%d vs %d)', numel(idx), numel(sym));
        end
    end
end

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
