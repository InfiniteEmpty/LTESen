%%
% LTE_waveform_generator.m
% =========================================================================
% LTE 下行波形生成器 —— 用于 SDR 平台验证小区干扰与 MUSIC 分离
% =========================================================================
% 每个 cellConfigs 元素对应一个独立小区。脚本会分别生成各小区的
% LTE 波形，再施加 PowerdB、CFOHz 和可选的采样点时延，最后叠加并
% 按 noiseConfig 加入 AWGN。

clear; clc; close all;

%% ====== 1. 参数设置 ======
NDLRB        = 100;            % 下行 RB 数: 6 / 15 / 25 / 50 / 75 / 100
CellRefP     = 1;              % 天线端口数: 1, 2, 4
DuplexMode   = 'FDD';          % 双工模式: 'FDD' | 'TDD'
CyclicPrefix = 'Normal';       % CP 类型

% --- 多小区配置列表 ---
% PowerdB 是相对于各小区“单位 RMS”波形的功率增益，使用幅度域换算：
%       linearGain = 10^(PowerdB/20)
% CFOHz 为施加到该小区上的频偏；正值表示基带频谱向正频率方向移动。
% TimingOffsetSamples 为整数采样点时延，正值表示该小区晚到达。
% Payload/PDSCH 字段可以让各小区使用不同的数据占用；不需要时保持为 0。
cellConfigs = [ ...
    struct('NCellID', 18, 'PowerdB',   0, 'CFOHz',    0, ...
           'TimingOffsetSamples',  0, 'PayloadRatio', 0.0, ...
           'PDSCHRBGDensity', 0.0, 'PDSCHPowerBoostdB', 0, ...
           'PDSCHModulation', 'QPSK', 'NFrame', 0), ...
    struct('NCellID', 35, 'PowerdB',  -20, 'CFOHz',  0.5, ...
           'TimingOffsetSamples',  0, 'PayloadRatio', 0.0, ...
           'PDSCHRBGDensity', 0.0, 'PDSCHPowerBoostdB', 0, ...
           'PDSCHModulation', 'QPSK', 'NFrame', 0), ...
    struct('NCellID', 37, 'PowerdB', -25, 'CFOHz', -0.2, ...
           'TimingOffsetSamples',  0, 'PayloadRatio', 0.0, ...
           'PDSCHRBGDensity', 0.0, 'PDSCHPowerBoostdB', 0, ...
           'PDSCHModulation', 'QPSK', 'NFrame', 0) ...
    ];

% --- 输出与重复 ---
amplitude    = 0.8;            % 合成信号整体峰值上限，建议 <= 1
numRepeats   = 500;            % 10 ms LTE 波形重复次数
fc_tx        = 1850;
output_dir   = 'experiment_data/tx_signal/LTE_20260831';
name_prefix  = 'LTE_20260831_000001';

% --- 噪声配置 ---
% SNRdB 是相对于“所有小区叠加后的干净信号”的平均功率信噪比。
% Seed=[] 表示使用当前随机数状态；填写整数可复现实验。
noiseConfig = struct('Enable', true, 'SNRdB', 30, 'Seed', 20260831);

validateCellConfigList(cellConfigs, amplitude);
validateNoiseConfig(noiseConfig);
numCells = numel(cellConfigs);

%% ====== 2. LTE 基础配置 ======
commonEnb = struct();
commonEnb.NDLRB        = NDLRB;
commonEnb.NCellID      = cellConfigs(1).NCellID;
commonEnb.CellRefP     = CellRefP;
commonEnb.DuplexMode   = DuplexMode;
commonEnb.CyclicPrefix = CyclicPrefix;
commonEnb.NFrame       = 0;
commonEnb.NSubframe    = 0;

% 动态设定控制域大小 (CFI)
if NDLRB <= 10
    commonEnb.CFI = 3;
else
    commonEnb.CFI = 2;
end
commonEnb.Ng           = 'Sixth';
commonEnb.PHICHDuration = 'Normal';

ofdmInfo = lteOFDMInfo(commonEnb);
sr = ofdmInfo.SamplingRate;

fprintf('\n========== LTE Multi-Cell Waveform Generator ==========\n');
fprintf('Bandwidth: %d RB (%.2f MHz), Sampling: %.3f MHz\n', ...
    NDLRB, sr/1e6, sr/1e6);
fprintf('Cells: %d, repeats: %d, output amplitude: %.3f\n', ...
    numCells, numRepeats, amplitude);
for cellIdx = 1:numCells
    fprintf('  Cell %03d: Power=%+g dB, CFO=%+g Hz, delay=%d samples\n', ...
        cellConfigs(cellIdx).NCellID, cellConfigs(cellIdx).PowerdB, ...
        cellConfigs(cellIdx).CFOHz, ...
        getCellConfig(cellConfigs(cellIdx), 'TimingOffsetSamples', 0));
end
if noiseConfig.Enable
    fprintf('AWGN: enabled, SNR=%.2f dB\n', noiseConfig.SNRdB);
else
    fprintf('AWGN: disabled\n');
end

%% ====== 3. 分别生成各小区的 LTE 波形 ======
fprintf('\n--- Generating %d independent LTE cells ---\n', numCells);
cellWaveforms = cell(1, numCells);
cellGrids = cell(1, numCells);
cellInfo = repmat(struct('NCellID', 0, 'TxRMS', 0, 'TxPeak', 0, ...
    'AllocatedRBG', 0, 'AllocatedPRB', 0), 1, numCells);

for cellIdx = 1:numCells
    [cellWaveforms{cellIdx}, cellGrids{cellIdx}, cellInfo(cellIdx)] = ...
        generateLteCellWaveform(commonEnb, cellConfigs(cellIdx));
end

%% ====== 4. 重复、施加 CFO/时延、功率合成与加噪 ======
fprintf('\n--- Applying per-cell CFO/gain and mixing ---\n');
firstRepeatedWaveform = repmat(cellWaveforms{1}, [numRepeats 1]);
mixedCleanWaveform = zeros(size(firstRepeatedWaveform));
mixInfo = repmat(struct('NCellID', 0, 'PowerdB', 0, 'CFOHz', 0, ...
    'TimingOffsetSamples', 0, 'LinearGain', 0, 'RMSAfterGain', 0), 1, numCells);

for cellIdx = 1:numCells
    cellCfg = cellConfigs(cellIdx);
    cellWaveform = repmat(cellWaveforms{cellIdx}, [numRepeats 1]);

    % 先按该小区自身 RMS 归一化，使 PowerdB 真正表示相对平均功率。
    cellRMS = sqrt(mean(abs(cellWaveform(:)).^2));
    cellWaveform = cellWaveform / max(cellRMS, eps);

    % CFO 在整个重复后的长序列上连续施加，避免每个 10 ms 块重新置相位。
    cfoHz = cellCfg.CFOHz;
    t = (0:size(cellWaveform, 1)-1).' / sr;
    cellWaveform = bsxfun(@times, cellWaveform, exp(1i * 2 * pi * cfoHz * t));

    timingOffset = getCellConfig(cellCfg, 'TimingOffsetSamples', 0);
    cellWaveform = applyIntegerDelay(cellWaveform, timingOffset);

    linearGain = 10^(cellCfg.PowerdB / 20);
    cellWaveform = cellWaveform * linearGain;
    mixedCleanWaveform = mixedCleanWaveform + cellWaveform;

    mixInfo(cellIdx).NCellID = cellCfg.NCellID;
    mixInfo(cellIdx).PowerdB = cellCfg.PowerdB;
    mixInfo(cellIdx).CFOHz = cfoHz;
    mixInfo(cellIdx).TimingOffsetSamples = timingOffset;
    mixInfo(cellIdx).LinearGain = linearGain;
    mixInfo(cellIdx).RMSAfterGain = sqrt(mean(abs(cellWaveform(:)).^2));
    fprintf('  Cell %03d: normalized RMS=1, applied RMS=%.5f\n', ...
        cellCfg.NCellID, mixInfo(cellIdx).RMSAfterGain);
end

% AWGN 的功率相对于干净合成信号定义；复高斯噪声的 I/Q 方差各占一半。
if noiseConfig.Enable && ~isinf(noiseConfig.SNRdB)
    previousRng = [];
    if ~isempty(noiseConfig.Seed)
        previousRng = rng;
        rng(noiseConfig.Seed, 'twister');
    end
    cleanPower = mean(abs(mixedCleanWaveform(:)).^2);
    noiseSigma = sqrt(cleanPower / (2 * 10^(noiseConfig.SNRdB / 10)));
    noiseWaveform = noiseSigma * (randn(size(mixedCleanWaveform)) + ...
        1i * randn(size(mixedCleanWaveform)));
    txWaveform = mixedCleanWaveform + noiseWaveform;
    if ~isempty(previousRng)
        rng(previousRng);
    end
else
    txWaveform = mixedCleanWaveform;
end

% 统一缩放整个混合信号，保持小区间相对功率和 SNR 不变。
maxAbs = max(abs(txWaveform(:)));
if maxAbs > 0
    outputScale = amplitude / maxAbs;
    txWaveform = txWaveform * outputScale;
else
    outputScale = 1;
end

fprintf('Composite clean RMS: %.5f\n', sqrt(mean(abs(mixedCleanWaveform(:)).^2)));
fprintf('Composite output RMS: %.5f, peak: %.5f\n', ...
    sqrt(mean(abs(txWaveform(:)).^2)), max(abs(txWaveform(:))));

%% ====== 5. 导出 ======
fprintf('\n--- Exporting mixed waveform ---\n');
if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

output_name = sprintf('%s_fc_%.0fM_fs_%.0fk', name_prefix, fc_tx, sr/1e3);

if noiseConfig.Enable
    output_name = [output_name sprintf('_AWGNSNR_%gdB', noiseConfig.SNRdB)];
end

% 保存 ground truth，便于 MUSIC 的 CFO/功率估计结果和输入参数逐项比较。
metadata_name = [output_name '_metadata.mat'];
save(fullfile(output_dir, metadata_name), 'cellConfigs', 'noiseConfig', ...
    'commonEnb', 'sr', 'fc_tx', 'amplitude', 'numRepeats', 'cellInfo', ...
    'mixInfo', 'outputScale');
fprintf('Saved metadata: %s\n', fullfile(output_dir, metadata_name));

if size(txWaveform, 2) > 1
    for p = 1:size(txWaveform, 2)
        file_name = output_name;
        file_name = [file_name sprintf('_port_%d', p-1)];   %#ok<AGROW>
        file_name = [file_name '_tp_single'];               %#ok<AGROW>
        file_path = fullfile(output_dir, [file_name '.bin']);
        write_gnuradio_format_file(file_path, txWaveform(:, p), 'single');
        fprintf('Saved: %s (RMS=%.5f, Peak=%.5f)\n', file_path, ...
            sqrt(mean(abs(txWaveform(:, p)).^2)), max(abs(txWaveform(:, p))));
    end
else
    file_name = output_name;
    file_name = [file_name '_tp_single'];
    file_path = fullfile(output_dir, [file_name '.bin']);
    write_gnuradio_format_file(file_path, txWaveform, 'single');
    fprintf('Saved: %s (RMS=%.5f, Peak=%.5f)\n', file_path, ...
        sqrt(mean(abs(txWaveform).^2)), max(abs(txWaveform)));
end

%% ====== 6. 可视化（第一个小区的资源网格） ======
txGrid = cellGrids{1};
figure('Name', 'LTE Multi-Cell Resource Grid', 'Position', [200, 200, 1000, 400]);
imagesc(1:size(txGrid,2), 1:size(txGrid,1), ...
    20*log10(abs(txGrid(:,:,1)) + 1e-6));
xlabel('OFDM Symbol Index'); ylabel('Subcarrier Index');
title(sprintf('Cell %d Resource Grid - %d RB, %d mixed cells', ...
    cellConfigs(1).NCellID, NDLRB, numCells));
colorbar; colormap('jet'); clim([-40 5]); axis xy;

%% ====== 辅助函数 ======
function [txWaveform, txGrid, info] = generateLteCellWaveform(commonEnb, cellCfg)
    % 为一个小区独立生成 10 ms LTE 下行波形。
    enb = commonEnb;
    enb.NCellID = cellCfg.NCellID;
    enb.NFrame = getCellConfig(cellCfg, 'NFrame', 0);

    payloadRatio = getCellConfig(cellCfg, 'PayloadRatio', 0.0);
    rbgDensity = getCellConfig(cellCfg, 'PDSCHRBGDensity', 0.0);
    pdschBoostdB = getCellConfig(cellCfg, 'PDSCHPowerBoostdB', 0);
    pdschModulation = getCellConfig(cellCfg, 'PDSCHModulation', 'QPSK');

    ofdmInfo = lteOFDMInfo(enb);
    symsPerSubframe = length(ofdmInfo.CyclicPrefixLengths);
    txGrid = zeros(enb.NDLRB * 12, 10 * symsPerSubframe, enb.CellRefP);

    % --- PDSCH / PDCCH 配置 ---
    if enb.CellRefP == 1
        pdsch.TxScheme = 'Port0';
        pdsch.NLayers = 1;
    else
        pdsch.TxScheme = 'TxDiversity';
        pdsch.NLayers = enb.CellRefP;
    end
    pdsch.Modulation = {pdschModulation};
    pdsch.RNTI = 1;
    pdsch.CSIMode = 'PUCCH 1-1';
    pdsch.CSIRefP = enb.CellRefP;
    pdsch.NTxAnts = enb.CellRefP;

    if enb.NDLRB <= 10
        P_rbg = 1;
    elseif enb.NDLRB <= 26
        P_rbg = 2;
    elseif enb.NDLRB <= 63
        P_rbg = 3;
    else
        P_rbg = 4;
    end
    nRBG = ceil(enb.NDLRB / P_rbg);
    nAllocRBG = round(rbgDensity * nRBG);
    allocPattern = false(1, nRBG);
    if nAllocRBG > 0
        selectedIdx = unique(round(linspace(1, nRBG, nAllocRBG)));
        allocPattern(selectedIdx) = true;
    end

    rbgBitmap = repmat('0', 1, nRBG);
    rbgBitmap(allocPattern) = '1';
    allocPRBs = [];
    for rbgIdx = find(allocPattern)
        rbStart = (rbgIdx - 1) * P_rbg;
        allocPRBs = [allocPRBs, rbStart:min(rbgIdx * P_rbg - 1, enb.NDLRB - 1)]; %#ok<AGROW>
    end
    pdsch.PRBSet = allocPRBs.';

    pdcchConfig.RNTI = 1;
    pdcchConfig.PDCCHFormat = 0;
    dciConfig.DCIFormat = 'Format1';
    dciConfig.AllocationType = 0;
    dciConfig.Allocation = rbgBitmap;

    fprintf('  Cell %03d: generating 10 subframes, PDSCH=%g%%\n', ...
        enb.NCellID, 100 * payloadRatio);
    for sf = 0:9
        enb.NSubframe = sf;
        sfGrid = lteResourceGrid(enb);

        % 填入 CRS、PSS、SSS。
        for p = 0:(enb.CellRefP - 1)
            sfGrid(lteCellRSIndices(enb, p)) = lteCellRS(enb, p);
        end
        if any(sf == [0 5])
            sfGrid = safeGridAssign(sfGrid, ltePSSIndices(enb), ltePSS(enb));
            sfGrid = safeGridAssign(sfGrid, lteSSSIndices(enb), lteSSS(enb));
        end

        % PBCH 周期为 40 ms；这里只取当前 10 ms 波形所需的 240 个符号。
        if sf == 0
            pbchSym = ltePBCH(enb, lteBCH(enb, lteMIB(enb)));
            pbchIdx = ltePBCHIndices(enb);
            frameOffset = mod(enb.NFrame, 4) * 240;
            pbchSym = pbchSym(frameOffset + (1:240), :);
            sfGrid = safeGridAssign(sfGrid, pbchIdx, pbchSym);
        end

        % 填入 PDCCH。
        [~, dciBits] = lteDCI(enb, dciConfig);
        if iscell(dciBits)
            dciBits = dciBits{1};
        end
        pdcchCW = lteDCIEncode(pdcchConfig, dciBits);
        pdcchSym = ltePDCCH(enb, pdcchCW);
        pdcchIdx = ltePDCCHIndices(enb);
        if ~iscell(pdcchIdx) && ~iscell(pdcchSym)
            pdcchIdx = pdcchIdx(1:size(pdcchSym, 1), :);
        end
        sfGrid = safeGridAssign(sfGrid, pdcchIdx, pdcchSym);

        % 填入 PDSCH。
        totalScale = sqrt(payloadRatio) * 10^(pdschBoostdB / 20);
        if totalScale > 0 && ~isempty(pdsch.PRBSet)
            [pdschIdx, pdschInfo] = ltePDSCHIndices(enb, pdsch, pdsch.PRBSet);
            if pdschInfo.G > 0
                codedBits = randi([0 1], pdschInfo.G, 1);
                pdschCW = ltePDSCH(enb, pdsch, codedBits);
                if iscell(pdschCW)
                    for ap = 1:length(pdschCW)
                        pdschCW{ap} = pdschCW{ap} * totalScale;
                    end
                else
                    pdschCW = pdschCW * totalScale;
                end
                sfGrid = safeGridAssign(sfGrid, pdschIdx, pdschCW);
            end
        end

        txGrid(:, (sf * symsPerSubframe + 1):((sf + 1) * symsPerSubframe), :) = sfGrid;
        fprintf('    SF%2d: Filled %d REs\n', sf, nnz(sfGrid));
    end

    txWaveform = lteOFDMModulate(enb, txGrid);
    info = struct('NCellID', enb.NCellID, ...
        'TxRMS', sqrt(mean(abs(txWaveform(:)).^2)), ...
        'TxPeak', max(abs(txWaveform(:))), ...
        'AllocatedRBG', nAllocRBG, ...
        'AllocatedPRB', numel(allocPRBs));
    fprintf('  Cell %03d: raw RMS=%.5f, peak=%.5f, allocated PRBs=%d\n', ...
        info.NCellID, info.TxRMS, info.TxPeak, info.AllocatedPRB);
end

function value = getCellConfig(cellCfg, fieldName, defaultValue)
    if isfield(cellCfg, fieldName) && ~isempty(cellCfg.(fieldName))
        value = cellCfg.(fieldName);
    else
        value = defaultValue;
    end
end

function validateCellConfigList(cellConfigs, amplitude)
    if ~isstruct(cellConfigs) || isempty(cellConfigs)
        error('cellConfigs must be a non-empty struct array.');
    end
    requiredFields = {'NCellID', 'PowerdB', 'CFOHz'};
    for k = 1:numel(requiredFields)
        if ~isfield(cellConfigs, requiredFields{k})
            error('cellConfigs is missing required field "%s".', requiredFields{k});
        end
    end
    if ~isscalar(amplitude) || ~isfinite(amplitude) || amplitude <= 0 || amplitude > 1
        error('amplitude must be in the range (0, 1].');
    end

    for idx = 1:numel(cellConfigs)
        cellCfg = cellConfigs(idx);
        if ~isnumeric(cellCfg.NCellID) || ~isscalar(cellCfg.NCellID) || ...
                cellCfg.NCellID ~= round(cellCfg.NCellID) || ...
                cellCfg.NCellID < 0 || cellCfg.NCellID > 503
            error('cellConfigs(%d).NCellID must be an integer in [0, 503].', idx);
        end
        if ~isnumeric(cellCfg.PowerdB) || ~isscalar(cellCfg.PowerdB) || ...
                ~isfinite(cellCfg.PowerdB)
            error('cellConfigs(%d).PowerdB must be a finite scalar.', idx);
        end
        if ~isnumeric(cellCfg.CFOHz) || ~isscalar(cellCfg.CFOHz) || ...
                ~isfinite(cellCfg.CFOHz)
            error('cellConfigs(%d).CFOHz must be a finite scalar.', idx);
        end

        payloadRatio = getCellConfig(cellCfg, 'PayloadRatio', 0);
        rbgDensity = getCellConfig(cellCfg, 'PDSCHRBGDensity', 0);
        if ~isnumeric(payloadRatio) || ~isscalar(payloadRatio) || ...
                ~isfinite(payloadRatio) || payloadRatio < 0 || payloadRatio > 1
            error('cellConfigs(%d).PayloadRatio must be in [0, 1].', idx);
        end
        if ~isnumeric(rbgDensity) || ~isscalar(rbgDensity) || ...
                ~isfinite(rbgDensity) || rbgDensity < 0 || rbgDensity > 1
            error('cellConfigs(%d).PDSCHRBGDensity must be in [0, 1].', idx);
        end

        timingOffset = getCellConfig(cellCfg, 'TimingOffsetSamples', 0);
        if ~isscalar(timingOffset) || ~isfinite(timingOffset) || ...
                timingOffset ~= round(timingOffset)
            error('cellConfigs(%d).TimingOffsetSamples must be an integer.', idx);
        end
        nFrame = getCellConfig(cellCfg, 'NFrame', 0);
        if ~isscalar(nFrame) || ~isfinite(nFrame) || nFrame ~= round(nFrame) || ...
                nFrame < 0 || nFrame > 1023
            error('cellConfigs(%d).NFrame must be an integer in [0, 1023].', idx);
        end
    end
end

function validateNoiseConfig(noiseConfig)
    if ~isstruct(noiseConfig) || ~isfield(noiseConfig, 'Enable') || ...
            ~isfield(noiseConfig, 'SNRdB') || ~isfield(noiseConfig, 'Seed')
        error('noiseConfig must contain Enable, SNRdB and Seed fields.');
    end
    if ~isscalar(noiseConfig.Enable)
        error('noiseConfig.Enable must be scalar.');
    end
    if ~isscalar(noiseConfig.SNRdB) || isnan(noiseConfig.SNRdB)
        error('noiseConfig.SNRdB must be a non-NaN scalar.');
    end
    if ~isempty(noiseConfig.Seed) && (~isscalar(noiseConfig.Seed) || ...
            ~isfinite(noiseConfig.Seed) || noiseConfig.Seed ~= round(noiseConfig.Seed))
        error('noiseConfig.Seed must be [] or an integer.');
    end
end

function y = applyIntegerDelay(x, delaySamples)
    % 对每个端口施加整数采样点时延，超出部分截断并补零。
    nSamples = size(x, 1);
    y = zeros(size(x), 'like', x);
    if delaySamples >= 0
        if delaySamples < nSamples
            y((delaySamples + 1):end, :) = x(1:(end - delaySamples), :);
        end
    else
        advance = -delaySamples;
        if advance < nSamples
            y(1:(end - advance), :) = x((advance + 1):end, :);
        end
    end
end

function sfGrid = safeGridAssign(sfGrid, idx, sym)
    % 适配单/多天线端口的资源映射，统一使用 numel 进行平铺校验。
    if iscell(idx) && iscell(sym)
        for p = 1:min(length(idx), length(sym))
            sfGrid(idx{p}) = sym{p};
        end
    elseif iscell(idx) && ~iscell(sym)
        allIdx = cell2mat(cellfun(@(c) c(:), idx(:), 'UniformOutput', false));
        if numel(allIdx) == numel(sym)
            sfGrid(allIdx) = sym(:);
        end
    elseif ~iscell(idx) && iscell(sym)
        allSym = cell2mat(cellfun(@(c) c(:), sym(:), 'UniformOutput', false));
        if numel(idx) == numel(allSym)
            sfGrid(idx(:)) = allSym;
        end
    else
        if numel(idx) == numel(sym)
            sfGrid(idx(:)) = sym(:);
        else
            warning('safeGridAssign:LengthMismatch', ...
                'Length mismatch (%d vs %d)', numel(idx), numel(sym));
        end
    end
end

function write_gnuradio_format_file(file_path, signal, writeType)
    %WRITE_GNURADIO_FORMAT_FILE 将复序列以 GNU Radio 交错 I/Q 格式写入文件。
    n = length(signal);
    interleaved = zeros(2 * n, 1);
    interleaved(1:2:end) = real(signal);
    interleaved(2:2:end) = imag(signal);

    fid = fopen(file_path, 'wb');
    if fid < 0
        error('Unable to open output file: %s', file_path);
    end
    fwrite(fid, interleaved, writeType);
    fclose(fid);
end
