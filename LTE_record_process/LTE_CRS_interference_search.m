%%
% LTE_CRS_interference_search.m
% =========================================================================
% CRS 互相关干扰小区搜索 —— 扫描 4G 录信号中的所有潜在同频/邻频小区
%
% 原理:
%   不同物理小区 ID (NCellID = 0..503) 会产生不同的 CRS (Cell-specific
%   Reference Signal) 时域波形。将接收信号与各候选小区 CRS 模板做互相关，
%   若某个 Cell ID 的信号真实存在于录波中，其相关峰将显著高于噪声底。
%
% 加速策略:
%   1. 预计算接收信号的 FFT —— 省去每次互相关时对 RX 信号的重复 FFT
%      (利用互相关定理: xcorr(a,b) = ifft( fft(a) × conj(fft(b)) ))
%   2. 将信号下采样至目标带宽 (NDLRB_search RB) —— 大幅减小 FFT 点数
%      且 PSS/SSS/CRS 均存在于中心 RB 中，不会丢失检测灵敏度
%   3. 预计算 CRS 位置模板 —— 6 种频域偏移共用同一模板骨架
%
% 依赖: MATLAB LTE Toolbox
% =========================================================================

clear; clc; close all;

%% ====== 1. 参数设置 ======

% --- 搜索范围 ---
cellID_search_range = 0:503;     % 全量扫描 (可改为子集 e.g. 0:50:503)
nSubframesToRead = 20;           % 从文件中读取的子帧数 (10 ms = 1 无线帧)
NDLRB_search = 50;               % 互相关使用的 RB 数 (6/15/25/50/75/100)
                                 % 越大越能利用 CRS 频域扩展增益，但 FFT 点数也越大
                                 % 典型值: 6=快扫, 50=全带宽高灵敏度

% --- 检测门限 ---
detection_sigma = 5;             % 检测门限 = median + sigma * MAD
                                 % 值越大越保守，避免虚警

% --- 高级选项 ---
enable_multiframe_coherent = false;  % 是否跨子帧相干累积 (增强 SNR)
n_coherent_subframes = 5;            % 相干累积的子帧数
enable_slide = true;                 % 是否滑动多个子帧位置取最大相关
n_slide_positions = 3;               % 滑动位置数

%% ====== 2. 数据加载 ======

[data_root, data_name] = autoLoadLTEFile('20260716', 2, false);
dataFile = LegacyLTEDataFile(fullfile(data_root, [data_name '.bin']));
file_path = dataFile.file_path;
fc = dataFile.frequency;
sr = dataFile.sample_rate;
c = physconst('LightSpeed');

rawSamplesPerSubframe = sr / 1000;
signal = dataFile.readAt(0, ...
    rawSamplesPerSubframe * nSubframesToRead, true);
rxWaveform = double(signal);

fprintf('\n========== CRS Interference Search ==========\n');
fprintf('File:      %s\n', file_path);
fprintf('Carrier:   %.1f MHz\n', fc/1e6);
fprintf('SampleRate: %.3f MHz\n', sr/1e6);
fprintf('Duration:  %.1f ms (%d subframes)\n', ...
    nSubframesToRead, nSubframesToRead);

%% ====== 3. 下采样至目标带宽 ======
% CRS 在全带宽上均有分布，降低带宽可大幅减小 FFT 点数加速扫描

enb_ref.NDLRB = NDLRB_search;
ofdmInfo_search = lteOFDMInfo(setfield(enb_ref, 'CyclicPrefix', 'Normal'));
target_sr = ofdmInfo_search.SamplingRate;

if abs(sr - target_sr) > 1
    fprintf('\n--- Downsampling ---\n');
    fprintf('  %.3f MHz → %.3f MHz (%d RB) ...\n', sr/1e6, target_sr/1e6, NDLRB_search);
    nSamples = ceil(target_sr / round(sr) * length(rxWaveform));
    rxWaveform_ds = resample(rxWaveform, target_sr, round(sr));
    rxWaveform_ds = rxWaveform_ds(1:nSamples);
else
    rxWaveform_ds = rxWaveform;
end

% --- 关键参数 ---
nfft = double(ofdmInfo_search.Nfft);
cpLens = ofdmInfo_search.CyclicPrefixLengths;
samplesPerSubframe = target_sr / 1000;
samplesPerSlot = samplesPerSubframe / 2;
nRxAnts = size(rxWaveform_ds, 2);

fprintf('  NDLRB: %d, Nfft: %d, Samples/subframe: %d, Total samples: %d\n', ...
    NDLRB_search, nfft, samplesPerSubframe, length(rxWaveform_ds));

%% ====== 3.5 频偏估计与校正 (CFO Correction) ======
% CFO 导致相位在子帧内旋转，严重破坏时域互相关。
% 参考 LTE_CRS_sense.m 第 164-184 行：
%   先通过 CP 相关估计频偏 (lteFrequencyOffset)，
%   再使用 lteFrequencyCorrect 进行补偿。
% CP 相关不依赖于 Cell ID，只依赖于 OFDM 符号结构。

fprintf('\n--- Frequency Offset Estimation & Correction ---\n');

% 尝试 FDD/TDD 两种双工模式，取频偏估计更合理的结果
duplexModes_cfo = {'FDD', 'TDD'};
best_cfo = 0;
best_cfo_rx = rxWaveform_ds;
cfo_quality = -Inf;

for dm = 1:length(duplexModes_cfo)
    enb_cfo.NDLRB = NDLRB_search;
    enb_cfo.CyclicPrefix = 'Normal';
    enb_cfo.DuplexMode = duplexModes_cfo{dm};
    enb_cfo.NCellID = 0;  % 任意值 —— CP 相关与 Cell ID 无关
    if strcmpi(enb_cfo.DuplexMode, 'TDD')
        enb_cfo.TDDConfig = 0;
        enb_cfo.SSC = 0;
    end

    try
        delta_f_try = lteFrequencyOffset(enb_cfo, rxWaveform_ds);
        rx_corrected_try = lteFrequencyCorrect(enb_cfo, rxWaveform_ds, delta_f_try);

        % 评估校正质量：校正后残余频偏应更小
        residual_f = lteFrequencyOffset(enb_cfo, rx_corrected_try);
        quality = -abs(residual_f);  % 残余越小越好

        fprintf('  [%s] estimated CFO: %+.3f Hz, residual: %+.3f Hz\n', ...
            duplexModes_cfo{dm}, delta_f_try, residual_f);

        if quality > cfo_quality
            cfo_quality = quality;
            best_cfo = delta_f_try;
            best_cfo_rx = rx_corrected_try;
        end
    catch
        fprintf('  [%s] CFO estimation failed, skipping.\n', duplexModes_cfo{dm});
    end
end

fprintf('  → Best CFO estimate: %+.3f Hz (%.2f ppm @ %.1f MHz)\n', ...
    best_cfo, best_cfo/fc*1e6, fc/1e6);

% 应用最佳频偏校正
rxWaveform_ds = best_cfo_rx;
clear best_cfo_rx rx_corrected_try;

%% ====== 3.6 可选: 运行小区搜索获取主小区参考 ======
% 通过 PSS/SSS 搜索找到最强小区，作为后续 CRS 互相关结果的验证基准。
% 同时也获取精确的定时偏移和频偏参考值。

fprintf('\n--- Primary Cell Search (for reference) ---\n');

searchalg.MaxCellCount = 2;
searchalg.SSSDetection = 'PostFFT';

enb_search.NDLRB = NDLRB_search;
enb_search.CyclicPrefix = 'Normal';
enb_search.CellRefP = 1;

peakMax = -Inf;
for duplexMode = {'FDD', 'TDD'}
    for cyclicPrefix = {'Normal', 'Extended'}
        enb_search.DuplexMode = duplexMode{1};
        enb_search.CyclicPrefix = cyclicPrefix{1};
        try
            [nCellID_try, offset_try, peak_try] = lteCellSearch(enb_search, ...
                rxWaveform_ds, searchalg);
            nCellID_try = nCellID_try(1);
            offset_try = offset_try(1);
            peak_try = peak_try(1);
            fprintf('  [%s/%s] NCellID=%d, offset=%d, peak=%.4f\n', ...
                duplexMode{1}, cyclicPrefix{1}, nCellID_try, offset_try, peak_try);
            if peak_try > peakMax
                peakMax = peak_try;
                primary_NCellID = nCellID_try;
                primary_offset = offset_try;
                primary_duplex = duplexMode{1};
                primary_cp = cyclicPrefix{1};
            end
        catch
            fprintf('  [%s/%s] Cell search failed.\n', duplexMode{1}, cyclicPrefix{1});
        end
    end
end

if peakMax > -Inf
    fprintf('  → Primary cell: NCellID=%d, offset=%d, peak=%.2f [%s/%s]\n', ...
        primary_NCellID, primary_offset, peakMax, primary_duplex, primary_cp);

    % 对主小区再做一次精细频偏估计 (使用正确的 NCellID)
    enb_search.NCellID = primary_NCellID;
    enb_search.DuplexMode = primary_duplex;
    enb_search.CyclicPrefix = primary_cp;
    delta_f_refined = lteFrequencyOffset(enb_search, rxWaveform_ds);
    fprintf('  → Refined CFO (with NCellID=%d): %+.3f Hz\n', ...
        primary_NCellID, delta_f_refined);

    % 如果精细估计与盲估计差别较大 (>100 Hz)，重新校正
    if abs(delta_f_refined - best_cfo) > 100
        fprintf('  → CFO refined significantly, re-applying correction...\n');
        rxWaveform_ds = lteFrequencyCorrect(enb_search, rxWaveform_ds, delta_f_refined);
        best_cfo = delta_f_refined;
    end
else
    fprintf('  ⚠ No primary cell found — proceeding with blind CFO estimate.\n');
    primary_NCellID = [];
    primary_offset = 0;
end

%% ====== 4. 预计算 CRS 时域基波形 (按频偏分组) ======
% CRS 在频域的位置仅由 v_shift = mod(NCellID, 6) 决定；
% 0..503 一共只有 6 种不同的 CRS 子载波位置模板。
% 预先生成 6 种"空位置"OFDM 网格骨架，省去每个 Cell ID 重复分配网格的开销。

fprintf('\n--- Pre-computing CRS grid templates (6 frequency shifts, %d RB) ---\n', NDLRB_search);

enb_base.NDLRB = NDLRB_search;
enb_base.CyclicPrefix = 'Normal';
enb_base.DuplexMode = 'FDD';
enb_base.CellRefP = 1;
enb_base.NSubframe = 0;

% 为 6 种频偏各生成一个资源网格模板 (标记 CRS 位置)
grid_templates = cell(6, 1);
crs_idx_templates = cell(6, 1);
crs_sym_templates = cell(6, 1);

for vshift = 0:5
    enb_base.NCellID = vshift;  % v_shift = mod(NCellID, 6)

    crs_grid = lteResourceGrid(enb_base);
    crs_idx = lteCellRSIndices(enb_base);
    crs_sym = lteCellRS(enb_base);

    % 存储模板索引 (符号值后续会被覆写)
    grid_templates{vshift+1} = crs_grid;
    crs_idx_templates{vshift+1} = crs_idx;
    crs_sym_templates{vshift+1} = crs_sym;
end

fprintf('  6 CRS position templates ready.\n');

%% ====== 5. 预计算接收信号 FFT (核心加速) ======
%
%  线性互相关定理:
%    r_xy[k] = Σ_n x[n] · conj(y[n-k])
%            = IFFT{ FFT{x, N} · conj(FFT{y, N}) }
%
%  其中 N >= len(x) + len(y) - 1
%  预计算 FFT{x} → 每个 Cell ID 只需 FFT{y} + IFFT

% 互相关模板长度: 单子帧 (或滑动/多帧)
M_template = samplesPerSubframe;

% FFT 点数: 保证线性相关不混叠
N_corr = 2^nextpow2(2 * M_template - 1);

fprintf('\n--- Pre-computing RX FFT (size %d) ---\n', N_corr);
fprintf('  Template length: %d samples (1 subframe)\n', M_template);

% 预计算接收信号各子帧位置的 FFT
nAvailableSubframes = floor(length(rxWaveform_ds) / samplesPerSubframe);
fprintf('  Available subframes: %d\n', nAvailableSubframes);

% 预计算多个子帧位置的 FFT 以支持滑动和相干累积
if enable_slide
    nSlide = min(n_slide_positions, nAvailableSubframes);
else
    nSlide = 1;
end

fft_rx_pool = cell(nSlide, 1);
for i = 1:nSlide
    idx_start = (i-1) * M_template + 1;
    idx_end = idx_start + M_template - 1;
    if idx_end > length(rxWaveform_ds)
        break;
    end
    fft_rx_pool{i} = fft(rxWaveform_ds(idx_start:idx_end), N_corr);
end
fprintf('  Pre-computed %d RX FFT(s).\n', nSlide);

%% ====== 6. 多帧相干累积模板 (可选) ======
if enable_multiframe_coherent
    nCoh = min(n_coherent_subframes, nAvailableSubframes);
    fprintf('\n--- Coherent multi-frame accumulation (%d subframes) ---\n', nCoh);

    % 拼接多子帧以增强 SNR (增加 FFT 点数)
    M_coherent = M_template * nCoh;
    N_corr_coherent = 2^nextpow2(2 * M_coherent - 1);

    fft_rx_coherent = fft(rxWaveform_ds(1:M_coherent), N_corr_coherent);
    fprintf('  Coherent FFT size: %d\n', N_corr_coherent);
else
    nCoh = 1;
    fft_rx_coherent = [];
    N_corr_coherent = N_corr;
end

%% ====== 7. 主搜索循环 ======

cellIDs = cellID_search_range(:);
nCells = length(cellIDs);

% 预分配结果数组
corr_peaks = zeros(nCells, 1);
corr_lags = zeros(nCells, 1);
corr_slide_idx = zeros(nCells, 1);  % 最佳滑动位置

fprintf('\n========== Scanning %d Cell IDs ==========\n', nCells);
fprintf('Optimizations:\n');
fprintf('  · Pre-computed RX FFT (saves 50%% FFT ops)\n');
fprintf('  · %d-RB downsampling (FFT size: %d vs %d for 50 RB)\n', NDLRB_search, N_corr, ...
    2^nextpow2(2 * 30720 - 1));
fprintf('  · 6 CRS position templates (reuse grid allocation)\n');
if enable_slide
    fprintf('  · Sliding over %d subframe positions\n', nSlide);
end
fprintf('-------------------------------------------\n');

tic;
last_progress = 0;

for idx = 1:nCells
    nCellID = cellIDs(idx);
    vshift = mod(nCellID, 6);

    % --- Step A: 填充 CRS 符号值 (复用位置模板) ---
    crs_grid = grid_templates{vshift+1};
    crs_idx = crs_idx_templates{vshift+1};
    enb_base.NCellID = nCellID;
    crs_sym = lteCellRS(enb_base);

    % 清零网格并按模板索引填入新 CRS 符号
    crs_grid(:) = 0;
    crs_grid(crs_idx) = crs_sym;

    % --- Step B: OFDM 调制 → 时域 CRS 波形 ---
    crsWaveform = lteOFDMModulate(enb_base, crs_grid);
    crs_template = crsWaveform(1:M_template);

    % --- Step C: 频域互相关 (预计算 FFT 加速) ---
    % 滑动多个子帧位置，取最大相关峰
    best_peak = -Inf;
    best_lag = 0;
    best_slide = 1;

    if enable_slide
        for s = 1:nSlide
            % 互相关: r = IFFT{ FFT_RX × conj(FFT_CRS) }
            xcorr_result = ifft(fft_rx_pool{s} .* conj(fft(crs_template, N_corr)));
            [pk, lag] = max(abs(xcorr_result));
            if pk > best_peak
                best_peak = pk;
                best_lag = lag;
                best_slide = s;
            end
        end
    else
        xcorr_result = ifft(fft_rx_pool{1} .* conj(fft(crs_template, N_corr)));
        [best_peak, best_lag] = max(abs(xcorr_result));
    end

    corr_peaks(idx) = best_peak;
    corr_lags(idx) = best_lag;
    corr_slide_idx(idx) = best_slide;

    % --- Progress ---
    if mod(idx, 100) == 0 || idx == nCells
        pct = idx / nCells * 100;
        elapsed = toc;
        eta = elapsed / idx * (nCells - idx);
        fprintf('  [%3.0f%%] %d/%d  |  elapsed: %.1fs  |  ETA: %.1fs\n', ...
            pct, idx, nCells, elapsed, eta);
    end
end

total_time = toc;
fprintf('-------------------------------------------\n');
fprintf('Scan complete: %d cells in %.1f seconds (%.1f ms/cell)\n', ...
    nCells, total_time, total_time/nCells*1000);

%% ====== 8. 结果分析与检测 ======

fprintf('\n========== Detection Results ==========\n');

% 归一化
corr_norm = corr_peaks / max(corr_peaks);

% 使用 MAD (Median Absolute Deviation) 设定稳健检测门限
median_peak = median(corr_peaks);
mad_peak = median(abs(corr_peaks - median_peak));
threshold_abs = median_peak + detection_sigma * mad_peak;
threshold_norm = threshold_abs / max(corr_peaks);

fprintf('Noise floor (median):  %.4f\n', median_peak);
fprintf('MAD:                   %.4f\n', mad_peak);
fprintf('Detection threshold:   %.4f  (%.1fσ above median)\n', ...
    threshold_abs, detection_sigma);
fprintf('Normalized threshold:  %.4f\n\n', threshold_norm);

% 选出高于门限的候选小区
detected_mask = corr_peaks > threshold_abs;
nDetected = sum(detected_mask);

if nDetected == 0
    fprintf('WARNING: No cell detected above threshold!\n');
    fprintf('  Try lowering detection_sigma (currently %d)\n', detection_sigma);
    fprintf('  or increasing nSubframesToRead.\n');

    % 仍列出 Top-10 供参考
    [peaks_sorted, sort_idx] = sort(corr_peaks, 'descend');
    fprintf('\n  Top-10 correlations (for reference):\n');
    fprintf('  %-6s %-10s %-14s %-12s\n', 'Rank', 'Cell ID', 'Norm. Corr.', 'Timing(samp)');
    for i = 1:min(10, nCells)
        cid = cellIDs(sort_idx(i));
        fprintf('  %-6d %-10d %-14.4f %-12d\n', ...
            i, cid, corr_peaks(sort_idx(i))/peaks_sorted(1), corr_lags(sort_idx(i)));
    end
else
    fprintf('>>> Detected %d cell(s) above threshold <<<\n\n', nDetected);

    % 按相关强度排序
    [peaks_detected, det_sort_idx] = sort(corr_peaks(detected_mask), 'descend');
    detected_cells = cellIDs(detected_mask);
    detected_cells = detected_cells(det_sort_idx);
    detected_peaks = peaks_detected;
    detected_lags = corr_lags(detected_mask);
    detected_lags = detected_lags(det_sort_idx);
    detected_slides = corr_slide_idx(detected_mask);
    detected_slides = detected_slides(det_sort_idx);

    fprintf('%-6s %-10s %-12s %-12s %-14s %-10s\n', ...
        'Rank', 'Cell ID', 'Peak', 'Norm.', 'Timing(samp)', 'SlidePos');
    fprintf('%s\n', repmat('-', 1, 65));
    for i = 1:nDetected
        fprintf('%-6d %-10d %-12.4f %-12.4f %-14d %-10d\n', ...
            i, detected_cells(i), detected_peaks(i), ...
            detected_peaks(i)/max(corr_peaks), ...
            detected_lags(i), detected_slides(i));
    end

    % --- 额外: 最近似小区检测 (可能含虚警) ---
    if nDetected > 1
        fprintf('\n--- Multi-cell verification note ---\n');
        fprintf('  If multiple cells are detected with similar timing offsets,\n');
        fprintf('  verify they are not harmonic artifacts by checking:\n');
        fprintf('    1. NCellID mod 3 (PSS identity) should differ\n');
        fprintf('    2. NCellID mod 6 (CRS v-shift) should differ or timing differ\n');

        for i = 1:min(nDetected, 10)
            cid = detected_cells(i);
            fprintf('  Cell %3d: PSS_ID=%d, v_shift=%d, timing=%d\n', ...
                cid, floor(cid/3), mod(cid,6), detected_lags(i));
        end
    end
end

%% ====== 9. 可视化 ======

figure('Name', 'LTE CRS Interference Search Results', ...
       'Position', [100, 100, 1400, 900]);

% --- Subplot 1: 全频段相关谱 ---
subplot(3, 2, [1 2]);
semilogy(cellIDs, corr_peaks, 'b-', 'LineWidth', 0.5);
hold on;
yline(threshold_abs, 'r--', 'LineWidth', 1.5, ...
    'DisplayName', sprintf('Threshold (median+%dσ MAD)', detection_sigma));
if nDetected > 0
    scatter(detected_cells, detected_peaks, 50, 'ro', 'filled', ...
        'DisplayName', sprintf('Detected (%d cells)', nDetected));
end
xlabel('Physical Cell ID (NCellID)');
ylabel('Cross-correlation Peak (linear scale)');
title(sprintf('CRS Cross-Correlation vs Cell ID (NDLRB=%d, %d candidates)', NDLRB_search, nCells));
legend('Location', 'best');
grid on;
xlim([min(cellIDs) max(cellIDs)]);

% --- Subplot 2: dB 尺度的前 30 候选 ---
subplot(3, 2, 3);
[peaks_sorted, sort_idx] = sort(corr_peaks, 'descend');
topN = min(30, nCells);
bar(1:topN, 10*log10(peaks_sorted(1:topN) + eps), 'FaceColor', [0.2 0.4 0.7]);
hold on;
yline(10*log10(threshold_abs + eps), 'r--', 'LineWidth', 1.5);
xlabel('Rank');
ylabel('Correlation Power (dB)');
title(sprintf('Top %d Cell IDs (dB scale)', topN));
xticks(1:2:topN);
xticklabels(string(cellIDs(sort_idx(1:2:topN))));
xtickangle(45);
grid on;

% --- Subplot 3: 物理层标识分组视图 ---
subplot(3, 2, 4);
% 按 PSS Identity (NCellID mod 3) 分组着色
colors = {'r', 'g', 'b'};
hold on;
for pss_id = 0:2
    mask = mod(cellIDs, 3) == pss_id;
    % 打散 x 坐标避免重叠
    x_jitter = cellIDs(mask) + (pss_id-1)*0.15;
    plot(x_jitter, 10*log10(corr_peaks(mask) + eps), '.', ...
        'Color', colors{pss_id+1}, 'MarkerSize', 6, ...
        'DisplayName', sprintf('PSS ID = %d', pss_id));
end
yline(10*log10(threshold_abs + eps), 'k--', 'LineWidth', 1);
xlabel('Cell ID');
ylabel('Correlation Power (dB)');
title('Colored by PSS Identity (N_{ID}^{(2)} = NCellID mod 3)');
legend('Location', 'best');
grid on;

% --- Subplot 4: CRS 频域偏移分组 (v_shift = NCellID mod 6) ---
subplot(3, 2, 5);
colors6 = lines(6);
hold on;
for vs = 0:5
    mask = mod(cellIDs, 6) == vs;
    scatter(cellIDs(mask), 10*log10(corr_peaks(mask) + eps), 12, ...
        colors6(vs+1,:), 'filled', ...
        'DisplayName', sprintf('v_{shift}=%d', vs));
end
yline(10*log10(threshold_abs + eps), 'k--', 'LineWidth', 1);
xlabel('Cell ID');
ylabel('Correlation Power (dB)');
title('Colored by CRS Frequency Shift (v_{shift} = NCellID mod 6)');
legend('Location', 'best');
grid on;

% --- Subplot 5: 相关峰时序偏移 ---
subplot(3, 2, 6);
scatter(cellIDs, corr_lags, 12, 10*log10(corr_peaks + eps), 'filled');
xlabel('Cell ID');
ylabel('Timing Offset (samples)');
title('CRS Correlation Timing Offset (color = correlation strength dB)');
colorbar;
grid on;
ylim([1 N_corr]);

sgtitle(sprintf(['CRS Interference Search — %s\n' ...
    '%d cells scanned | %d detected | Threshold = median + %dσ MAD'], ...
    file_path, nCells, nDetected, detection_sigma), ...
    'Interpreter', 'none', 'FontWeight', 'bold');

%% ====== 10. 最强小区的逐子帧相关验证 ======

if nDetected > 0
    bestCellID = detected_cells(1);

    fprintf('\n========== Detailed Verification: Cell ID %d ==========\n', bestCellID);

    % 生成 CRS 模板
    enb_base.NCellID = bestCellID;
    vshift = mod(bestCellID, 6);
    crs_grid = grid_templates{vshift+1};
    crs_idx = crs_idx_templates{vshift+1};
    crs_grid(:) = 0;
    crs_grid(crs_idx) = lteCellRS(enb_base);
    crsWaveform = lteOFDMModulate(enb_base, crs_grid);
    crs_template = crsWaveform(1:M_template);
    fft_crs_template = fft(crs_template, N_corr);

    % 逐子帧计算相关峰
    nSubframesVerify = min(nAvailableSubframes, 100);
    subframe_peaks = zeros(nSubframesVerify, 1);
    subframe_lags = zeros(nSubframesVerify, 1);

    for sf = 1:nSubframesVerify
        idx_start = (sf-1) * M_template + 1;
        idx_end = idx_start + M_template - 1;
        if idx_end > length(rxWaveform_ds)
            break;
        end
        rx_chunk = rxWaveform_ds(idx_start:idx_end);
        xcorr_sf = ifft(fft(rx_chunk, N_corr) .* conj(fft_crs_template));
        [subframe_peaks(sf), subframe_lags(sf)] = max(abs(xcorr_sf));
    end

    figure('Name', sprintf('Cell ID %d - Per-Subframe Verification', bestCellID));

    subplot(2, 1, 1);
    plot(0:nSubframesVerify-1, 10*log10(subframe_peaks + eps), 'b-o', ...
        'LineWidth', 1, 'MarkerSize', 4);
    xlabel('Subframe Index');
    ylabel('Correlation Peak (dB)');
    title(sprintf('Cell ID %d: CRS Correlation Across %d Subframes', ...
        bestCellID, nSubframesVerify));
    grid on;

    subplot(2, 1, 2);
    stem(0:nSubframesVerify-1, subframe_lags, 'LineWidth', 0.5);
    xlabel('Subframe Index');
    ylabel('Timing Offset (samples)');
    title('Timing Offset Consistency Check');
    grid on;

    fprintf('  Peak mean:    %.2f dB\n', 10*log10(mean(subframe_peaks) + eps));
    fprintf('  Peak std:     %.2f dB\n', 10*log10(std(subframe_peaks) + eps));
    fprintf('  Timing range: %d - %d samples\n', min(subframe_lags), max(subframe_lags));

    if std(subframe_lags) < 10
        fprintf('  ✓ Timing stable — high confidence detection\n');
    else
        fprintf('  ⚠ Timing unstable — possible false detection or strong interference\n');
    end
end

fprintf('\n========== Script Complete ==========\n');
