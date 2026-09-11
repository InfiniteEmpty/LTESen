%%

clear;
clc;
close all;

%% Basic Parameters

% 仅用于加载文件名
base_dir = 'experiment_data/rx_signal';
prefix_str = 'LTE';
data_str = '20260711';
idx_str = sprintf('%06d', 12);

root_dir = [base_dir '/LTE_' data_str];
record_name = [prefix_str '_' data_str '_' idx_str];

% 旧 .bin
dataFile = LegacyLTEDataFile(root_dir, record_name);
% 单条 SigMF
% dataFile = SigMFDataFile(root_dir, record_name);
% SigMF Collection
% dataCollection = SigMFCollection(root_dir, record_name);
% dataFile = dataCollection.streams(2);

fc = round(dataFile.frequency);
sr = round(dataFile.sample_rate);
c = physconst('LightSpeed');

headStart = 307200*10;
headFrame = dataFile.readAt(headStart, 307200*5, true);

%%
% Prior to decoding the MIB, the UE does not know the full system
% bandwidth. The primary and secondary synchronization signals (PSS and
% SSS) and the PBCH (containing the MIB) all lie in the central 72
% subcarriers (6 resource blocks) of the system bandwidth, allowing the UE
% to initially demodulate just this central region. Therefore the bandwidth
% is initially set to 6 resource blocks. The I/Q waveform needs to be
% resampled accordingly. At this stage we also display the spectrum of the
% input signal |eNodeBOutput|.

% Set up some housekeeping variables:
% separator for command window logging
separator = repmat('-',1,50);
% plots
if (~exist('channelFigure','var') || ~isvalid(channelFigure))
    channelFigure = figure('Visible','off');        
end
[spectrumScope,synchCorrPlot,pdcchConstDiagram] = ...
    hSIB1RecoveryExamplePlots(channelFigure,sr);
% PDSCH EVM
pdschEVM = comm.EVM();
pdschEVM.MaximumEVMOutputPort = true;

% The sampling rate for the initial cell search is established using 
% lteOFDMInfo configured for 6 resource blocks. enb.CyclicPrefix is set
% temporarily in the call to lteOFDMInfo to suppress a default value
% warning (it does not affect the sampling rate).
enb = struct;                   % eNodeB config structure
enb.NDLRB = 6;                  % Number of resource blocks
ofdmInfo = lteOFDMInfo(setfield(enb,'CyclicPrefix','Normal')); %#ok<SFLD>

if (isempty(headFrame))
    fprintf('\nReceived signal must not be empty.\n');
    return;
end

% Display received signal spectrum
fprintf('\nPlotting received signal spectrum...\n');
spectrumScope(awgn(headFrame, 100.0));

if (sr~=ofdmInfo.SamplingRate)
    if (sr < ofdmInfo.SamplingRate)
        warning('The received signal sampling rate (%0.3fMs/s) is lower than the desired sampling rate for cell search / MIB decoding (%0.3fMs/s); cell search / MIB decoding may fail.',sr/1e6,ofdmInfo.SamplingRate/1e6);
    end
    fprintf('\nResampling from %0.3fMs/s to %0.3fMs/s for cell search / MIB decoding...\n',sr/1e6,ofdmInfo.SamplingRate/1e6);
else
    fprintf('\nResampling not required; received signal is at desired sampling rate for cell search / MIB decoding (%0.3fMs/s).\n',sr/1e6);
end
% Downsample received signal
nSamples = ceil(ofdmInfo.SamplingRate/round(sr)*size(headFrame,1));
nRxAnts = size(headFrame, 2);
downsampled = zeros(nSamples, nRxAnts);
for i=1:nRxAnts
    downsampled(:,i) = resample(headFrame(:,i), ofdmInfo.SamplingRate, round(sr));
end

%% Cell Search, Cyclic Prefix Length and Duplex Mode Detection
% Call <docid:lte_ref#bt1vu8s lteCellSearch> to obtain the cell 
% identity and timing offset |offset| to the first frame head. The cell
% search is repeated for each combination of cyclic prefix length and
% duplex mode, and the combination with the strongest correlation allows
% these parameters to be identified. A plot of the correlation between the
% received signal and the PSS/SSS for the detected cell identity is 
% produced. The PSS is detected using time-domain correlation and the SSS
% is detected using frequency-domain correlation. Prior to SSS detection,
% frequency offset estimation/correction using cyclic prefix correlation is
% performed. The time-domain PSS detection is robust to small frequency
% offsets but larger offsets may degrade the PSS correlation.

fprintf('\nPerforming cell search...\n');

% Set up duplex mode and cyclic prefix length combinations for search; if
% either of these parameters is configured in |enb| then the value is
% assumed to be correct
if (~isfield(enb,'DuplexMode'))
    duplexModes = {'TDD' 'FDD'};
else
    duplexModes = {enb.DuplexMode};
end
if (~isfield(enb,'CyclicPrefix'))
    cyclicPrefixes = {'Normal' 'Extended'};
else
    cyclicPrefixes = {enb.CyclicPrefix};
end

% Perform cell search across duplex mode and cyclic prefix length
% combinations and record the combination with the maximum correlation; if
% multiple cell search is configured, this example will decode the first
% (strongest) detected cell
searchalg.MaxCellCount = 2;
searchalg.SSSDetection = 'PostFFT';
peakMax = -Inf;
for duplexMode = duplexModes
    for cyclicPrefix = cyclicPrefixes
        enb.DuplexMode = duplexMode{1};
        enb.CyclicPrefix = cyclicPrefix{1};
        [enb.NCellID, offset, peak] = lteCellSearch(enb, downsampled, searchalg);
        enb.NCellID = enb.NCellID(1);
        offset = offset(1);
        peak = peak(1);
        if (peak>peakMax)
            enbMax = enb;
            offsetMax = offset;
            peakMax = peak;
        end
    end
end

% Use the cell identity, cyclic prefix length, duplex mode and timing
% offset which gave the maximum correlation during cell search
enb = enbMax;
offset = offsetMax;

% Compute the correlation for each of the three possible primary cell
% identities; the peak of the correlation for the cell identity established
% above is compared with the peak of the correlation for the other two
% primary cell identities in order to establish the quality of the
% correlation.
corr = cell(1,3);
idGroup = floor(enbMax.NCellID/3);
for i = 0:2
    enb.NCellID = idGroup*3 + mod(enbMax.NCellID + i,3);
    [~,corr{i+1}] = lteDLFrameOffset(enb, downsampled);
    corr{i+1} = sum(corr{i+1},2);
end
threshold = 1.3 * max([corr{2}; corr{3}]); % multiplier of 1.3 empirically obtained
if (max(corr{1})<threshold)    
    warning('Synchronization signal correlation was weak; detected cell identity may be incorrect.');
end
% Return to originally detected cell identity
enb.NCellID = enbMax.NCellID;

% Plot PSS/SSS correlation and threshold
synchCorrPlot.YLimits = [0 max([corr{1}; threshold])*1.1];
synchCorrPlot([corr{1} threshold*ones(size(corr{1}))]);

% Perform timing synchronization
fprintf('Timing offset to frame start: %d samples\n',offset);
downsampled = downsampled(1+offset:end,:); 
enb.NSubframe = 0;

% Show cell-wide settings
fprintf('Cell-wide settings after cell search:\n');
disp(enb);


%% Frequency Offset Estimation and Correction
% Prior to OFDM demodulation, any significant frequency offset must be
% removed. The frequency offset in the I/Q waveform is estimated and
% corrected using <docid:lte_ref#bt25auu lteFrequencyOffset> and
% <docid:lte_ref#bt2fcvq lteFrequencyCorrect>. The frequency
% offset is estimated by means of correlation of the cyclic prefix and
% therefore can estimate offsets up to +/- half the subcarrier spacing i.e.
% +/- 7.5kHz.

fprintf('\nPerforming frequency offset estimation...\n');
% For TDD, TDDConfig and SSC are defaulted to 0. These parameters are not
% established in the system until SIB1 is decoded, so at this stage the
% values of 0 make the most conservative assumption (fewest downlink
% subframes and shortest special subframe).
if (strcmpi(enb.DuplexMode,'TDD'))
    enb.TDDConfig = 0;
    enb.SSC = 0;
end
delta_f = lteFrequencyOffset(enb, downsampled);
fprintf('Frequency offset: %0.3fHz\n',delta_f);
downsampled = lteFrequencyCorrect(enb, downsampled, delta_f);

%% OFDM Demodulation and Channel Estimation  
% The OFDM downsampled I/Q waveform is demodulated to produce a resource
% grid |rxgrid|. This is used to perform channel estimation. |hest| is the
% channel estimate, |nest| is an estimate of the noise (for MMSE
% equalization) and |cec| is the channel estimator configuration.
%
% For channel estimation the example assumes 4 cell specific reference
% signals. This means that channel estimates to each receiver antenna from
% all possible cell-specific reference signal ports are available. The true
% number of cell-specific reference signal ports is not yet known. The
% channel estimation is only performed on the first subframe, i.e. using
% the first |L| OFDM symbols in |rxgrid|.
%
% A conservative 13-by-9 pilot averaging window is used, in frequency and
% time, to reduce the impact of noise on pilot estimates during channel
% estimation.

% Channel estimator configuration
cec.PilotAverage = 'UserDefined';     % Type of pilot averaging
cec.FreqWindow = 13;                  % Frequency window size    
cec.TimeWindow = 9;                   % Time window size    
cec.InterpType = 'cubic';             % 2D interpolation type
cec.InterpWindow = 'Centered';        % Interpolation window type
cec.InterpWinSize = 1;                % Interpolation window size  

% Assume 4 cell-specific reference signals for initial decoding attempt;
% ensures channel estimates are available for all cell-specific reference
% signals
enb.CellRefP = 4;   
                    
fprintf('Performing OFDM demodulation...\n\n');

griddims = lteResourceGridSize(enb); % Resource grid dimensions
L = griddims(2);                     % Number of OFDM symbols in a subframe 
% OFDM demodulate signal 
rxgrid = lteOFDMDemodulate(enb, downsampled);    
if (isempty(rxgrid))
    fprintf('After timing synchronization, signal is shorter than one subframe so no further demodulation will be performed.\n');
    return;
end
% Perform channel estimation
[hest, nest] = lteDLChannelEstimate(enb, cec, rxgrid(:,1:L,:));

%% PBCH Demodulation, BCH Decoding, MIB Parsing
% The MIB is now decoded along with the number of cell-specific reference
% signal ports transmitted as a mask on the BCH CRC. The function
% <docid:lte_ref#bt3d9rv ltePBCHDecode> establishes frame timing
% modulo 4 and returns this in the |nfmod4| parameter. It also returns the
% MIB bits in vector |mib| and the true number of cell-specific reference
% signal ports which is assigned into |enb.CellRefP| at the output of this
% function call. If the number of cell-specific reference signal ports is
% decoded as |enb.CellRefP=0|, this indicates a failure to decode the BCH.
% The function <docid:lte_ref#bt293au lteMIB> is used to parse the bit
% vector |mib| and add the relevant fields to the configuration structure
% |enb|. After MIB decoding, the detected bandwidth is present in
% |enb.NDLRB|. 

% Decode the MIB
% Extract resource elements (REs) corresponding to the PBCH from the first
% subframe across all receive antennas and channel estimates
fprintf('Performing MIB decoding...\n');
pbchIndices = ltePBCHIndices(enb);
[pbchRx, pbchHest] = lteExtractResources( ...
    pbchIndices, rxgrid(:,1:L,:), hest(:,1:L,:,:));

% Decode PBCH
[bchBits, pbchSymbols, nfmod4, mib, enb.CellRefP] = ltePBCHDecode( ...
    enb, pbchRx, pbchHest, nest); 

% Parse MIB bits
enb = lteMIB(mib, enb); 

% Incorporate the nfmod4 value output from the function ltePBCHDecode, as
% the NFrame value established from the MIB is the System Frame Number
% (SFN) modulo 4 (it is stored in the MIB as floor(SFN/4))
enb.NFrame = enb.NFrame+nfmod4;

% Display cell wide settings after MIB decoding
fprintf('Cell-wide settings after MIB decoding:\n');
disp(enb);

if (enb.CellRefP==0)
    fprintf('MIB decoding failed (enb.CellRefP=0).\n\n');
    return;
end
if (enb.NDLRB==0)
    fprintf('MIB decoding failed (enb.NDLRB=0).\n\n');
    return;
end

%% OFDM Demodulation on Full Bandwidth
% Now that the signal bandwidth is known, the signal is resampled to the
% nominal sampling rate used by LTE Toolbox for that bandwidth (see
% <docid:lte_ref#bt0lmvf_1 lteOFDMModulate> for details). Frequency
% offset estimation and correction is performed on the resampled signal.
% Timing synchronization and OFDM demodulation are then performed.

fprintf('Restarting reception now that bandwidth (NDLRB=%d) is known...\n',enb.NDLRB);

% Resample now we know the true bandwidth
ofdmInfo = lteOFDMInfo(enb);
if (sr~=ofdmInfo.SamplingRate)
    if (sr < ofdmInfo.SamplingRate)
        warning('The received signal sampling rate (%0.3fMs/s) is lower than the desired sampling rate for NDLRB=%d (%0.3fMs/s); PDCCH search / SIB1 decoding may fail.',sr/1e6,enb.NDLRB,ofdmInfo.SamplingRate/1e6);
    end    
    fprintf('\nResampling from %0.3fMs/s to %0.3fMs/s...\n',sr/1e6,ofdmInfo.SamplingRate/1e6);
else
    fprintf('\nResampling not required; received signal is at desired sampling rate for NDLRB=%d (%0.3fMs/s).\n',enb.NDLRB,sr/1e6);
end
nSamples = ceil(ofdmInfo.SamplingRate/round(sr)*size(headFrame,1));
resampled = zeros(nSamples, nRxAnts);
for i = 1:nRxAnts
    resampled(:,i) = resample(headFrame(:,i), ofdmInfo.SamplingRate, round(sr));
end

% Perform frequency offset estimation and correction
fprintf('\nPerforming frequency offset estimation...\n');
delta_f = lteFrequencyOffset(enb, resampled);
fprintf('Frequency offset: %0.3fHz\n',delta_f);
resampled = lteFrequencyCorrect(enb, resampled, delta_f);

% Find beginning of frame
fprintf('\nPerforming timing offset estimation...\n');
offset = lteDLFrameOffset(enb, resampled); 
fprintf('Timing offset to frame start: %d samples\n',offset);
% Aligning signal with the start of the frame
resampled = resampled(1+offset:end,:);   

% OFDM demodulation
fprintf('\nPerforming OFDM demodulation...\n\n');
rxgrid = lteOFDMDemodulate(enb, resampled);

%% Fast Channel State Information (CSI) Extraction with Recursive SFO/CFO Correction

fprintf('%s\n',separator);
fprintf('Performing Memory-Safe Recursive CSI Extraction & SFO/CFO Correction\n');
fprintf('%s\n\n',separator);

% 如果有多天线，暂时只使用前两根
enb.CellRefP = min(enb.CellRefP, 2);

% 1. 获取时域与频域的基础参数
lte_sr = double(ofdmInfo.SamplingRate); % LTE 基带处理采样率
raw_sr = sr;                            % 原始文件采样率 (例如 30.72 MHz)

% 计算每次需要从文件中读取的原始采样点数
rawSamplesPerSubframe = round(raw_sr / 1000);
lteSamplesPerSubframe = round(lte_sr / 1000);

nfft = double(ofdmInfo.Nfft);
cpLenList = ofdmInfo.CyclicPrefixLengths; 
ang2Freq = lte_sr / nfft / (2*pi); 
tLim = (0:lteSamplesPerSubframe-1).' / lte_sr;

nTx = enb.CellRefP;
nRx = 1;
N_carrier = double(enb.NDLRB * 12);
N_crs_freq = double(enb.NDLRB * 2);

% 2. 计算文件的总可用子帧数
total_raw_samples = dataFile.sample_count;
% readOffset 需要是相对于原始文件的采样点偏移量
% (你需要根据之前的初始同步结果将其换算为针对 raw_sr 的 offset)
readOffset = offset + headStart;
numSubframes = floor((total_raw_samples - readOffset) / rawSamplesPerSubframe) - 2;

% 3. 初始化 SFO/CFO 追踪变量与低通滤波器
cfoFreq = delta_f; 
sfoIntCorrect = 0;
symbolShift = 0;

% 初始化 5 阶 Butterworth 低通滤波器
[lpB, lpA] = butter(5, pi/512, 'low');
lp_order = max(length(lpA), length(lpB)) - 1;

% 为 G1 和 G2 分别分配包含所有天线链路与子载波的滤波器状态矩阵
% 维度：[滤波器阶数, 子载波数量, 接收天线数, 发射天线数]
lpState_G1 = zeros(lp_order, N_crs_freq, nRx, nTx);
lpState_G2 = zeros(lp_order, N_crs_freq, nRx, nTx);

staticCSI_G1 = ones(N_crs_freq, 1, nRx, nTx);
staticCSI_G2 = ones(N_crs_freq, 1, nRx, nTx);

% 4. 去除周期性干扰
if ~exist('CSI_inter_G1', 'var')
    CSI_inter_G1 = zeros(N_crs_freq, 20, 1, nRx, nTx);
    CSI_inter_G2 = zeros(N_crs_freq, 20, 1, nRx, nTx);
end
% 需要考虑 csi_inter 的更新

% 初始化帧号、子帧号
current_NFrame = enb.NFrame;
current_NSubframe = 0; % 由于经过时钟同步，信号从子帧 0 齐头开始

% 同一个当前列锚定插值器服务两个统计量：
% 1) 逐样本联合计算频率延迟/慢时间延迟的二维自相关，并连续指数累加；
% 2) 完整 200 列重采样 CSI 只用于当前窗口的 2D-FFT R-D。
win_NFrame = 10;
win_NSymb = 20 * win_NFrame; % 需要是每帧 CRS 列数(20)的整数倍
slowTimeSamplePeriod = 5e-4; % G1 同一子载波每个 slot 采一次
senseRx = 1;
senseTx = 1;
senseMaxSubframes = Inf; % 可改为较小值，先试跑一小段数据
numSubframes = min(numSubframes, senseMaxSubframes);
assert(senseRx <= nRx && senseTx <= nTx, 'Invalid sensing antenna index.');

% sinc 近邻精确计算，远场使用高阶递推；阶数由容差和最大偏移自动选取。
% guard 仅增加较旧的历史支持，不引入未来数据，不改变最新列锚点。
resampleKernelTolerance = 1e-8;
resampleGuardSamples = 12;
anchoredResampler = [];
jointCorrelationState = [];
carrierOffsetsHz = [];
jointRangeOrder = 24;
jointDopplerOrder = 24;
jointForgettingFactor = 0.998;
jointSpectrumUpdateSamples = 200; % 仅控制求解和绘图，二维相关逐样本更新
jointSubarraySize = (jointRangeOrder+1)*(jointDopplerOrder+1);
musicSignalCount = 20; % 假定的目标/信号子空间维数，需按场景调整
jointMinimumUpdates = max(4*jointSubarraySize, 32);
musicDiagonalLoading = 1e-3;
validateattributes(jointRangeOrder, {'numeric'}, {'scalar', 'integer', 'positive'});
validateattributes(jointDopplerOrder, {'numeric'}, {'scalar', 'integer', 'positive'});
validateattributes(musicSignalCount, {'numeric'}, {'scalar', 'integer', 'positive'});
assert(musicSignalCount < jointSubarraySize, ...
    'musicSignalCount must be smaller than the virtual subarray size.');
assert(jointForgettingFactor > 0 && jointForgettingFactor <= 1, ...
    'jointForgettingFactor must be in the interval (0, 1].');
% 每次新样本 n 同时生成整个矩阵：
% q(df,dt)=mean_f x(f,n)*conj(x(f-df*DeltaF,n-dt))，
% numerator=lambda*numerator+q，weight=lambda*weight+1。
% 这里没有先沿任一维压缩，因而保留二维联合相位。
jointLastSpectrumSample = 0;
jointRangePoints = nfft;
jointDopplerPoints = 4 * win_NSymb;
dopplerHz = (-jointDopplerPoints/2:jointDopplerPoints/2-1) ...
    / (jointDopplerPoints*slowTimeSamplePeriod);
% x(t)=exp(-j*2*pi*fc*2R(t)/c)，正速度对应负 Doppler。
[v_lim, velocityOrder] = sort(-dopplerHz*c/(2*fc));
v_mask = true(size(v_lim)); % 例如 abs(v_lim) < 30
% 实际 15 kHz 网格补零后作距离 IFFT；显示原 CRS 间隔对应的主距离区间。
rdRangeFftLength = nfft;
crsSpacingHz = 6*(lte_sr/nfft);
rdRangeHalfSpan = c/(4*crsSpacingHz);
jointRangeBins = -floor(jointRangePoints/2):ceil(jointRangePoints/2)-1;
jointRangeAxis = jointRangeBins*c/(2*crsSpacingHz*jointRangePoints);
% MUSIC 空间角频率与距离反号；+pi 与 -pi 是同一周期点。
jointSpatialBins = mod(-jointRangeBins+floor(jointRangePoints/2), ...
    jointRangePoints)-floor(jointRangePoints/2);
[spatialBinsFound, jointRangeDisplayOrder] = ismember( ...
    jointSpatialBins, jointRangeBins);
assert(all(spatialBinsFound), 'Failed to construct the joint AR range axis.');
jointRangeMask = jointRangeAxis >= -rdRangeHalfSpan & ...
    jointRangeAxis < rdRangeHalfSpan;
fftNoiseFloor = [];
fftDisplayRange = [];

rdFigure = figure('Name', 'Joint 2-D MUSIC and 2D-FFT R-D', 'Visible', 'on');
spectrumLayout = tiledlayout(rdFigure, 2, 1, ...
    'TileSpacing', 'compact');
jointAxes = nexttile(spectrumLayout);
jointImage = [];
title(jointAxes, 'Continuous joint 2-D MUSIC R-D: warming up');
rdAxes = nexttile(spectrumLayout);
rdImage = [];
title(rdAxes, '2D-FFT R-D: waiting for a complete CSI window');

for sfIdx = 1:numSubframes
    
    % --- Step A: 动态内存映射读取与 SFO 整数漂移补偿 ---
    % 注意：sfoIntCorrect 是在重采样后的 LTE 采样率域的偏移
    % 需要将其按比例映射回原始文件的读取偏移中
    raw_sfo_shift = round(sfoIntCorrect * (raw_sr / lte_sr));
    
    % 通过数据对象按原始采样点偏移读取一个子帧。
    % 保持原有 memmapfile 分支的行为：不做归一化，并转换为 single。
    rawSampleOffset = readOffset + (sfIdx-1)*rawSamplesPerSubframe + raw_sfo_shift;
    rxWaveform_raw = single(dataFile.readAt( ...
        rawSampleOffset, rawSamplesPerSubframe, false));
    
    % --- Step B: 动态重采样 ---
    if raw_sr ~= lte_sr
        rxWaveform = resample(rxWaveform_raw, lte_sr, raw_sr);
        % 确保长度严格等于 lteSamplesPerSubframe
        rxWaveform = rxWaveform(1:lteSamplesPerSubframe, :);
    else
        rxWaveform = rxWaveform_raw;
    end
    
    % --- Step C: 时域粗略 CFO 校正 ---
    cfoCorVec = exp(-2i*pi*cfoFreq*tLim);
    coarseWave = rxWaveform .* cfoCorVec;

    % 提取 CP 计算新频偏
    % frontSegment = coarseWave(1:cpLen, 1);
    % tailSegment = coarseWave(nfft+1:nfft+cpLen, 1);
    % newOffset = angle(sum(tailSegment .* conj(frontSegment))) * ang2Freq;
    % cfoFreq = cfoFreq + newOffset;
    % 留出保护间隔
    frontStart = 10;
    tailStart = frontStart + nfft;
    sumMixSeg = 0;
    for cpLen = cpLenList
        cpUse = cpLen - 20;
        frontSegment = coarseWave(frontStart:frontStart+cpUse-1, 1);
        tailSegment = coarseWave(tailStart:tailStart+cpUse-1, 1);
        sumMixSeg = sumMixSeg + sum(tailSegment .* conj(frontSegment));
        frontStart = frontStart + nfft + cpLen;
        tailStart = tailStart + nfft + cpLen;
    end
    newOffset = angle(sumMixSeg) * ang2Freq;
    cfoFreq = cfoFreq + newOffset;

    % 施加更新后的 CFO
    cfoCorVec = exp(-2i*pi*cfoFreq*tLim);
    rxWaveform = rxWaveform .* cfoCorVec;
    
    % --- Step D: OFDM 解调与 CSI 提取 ---
    enb.NFrame = current_NFrame;
    enb.NSubframe = current_NSubframe;
    % rxsubframe = lteOFDMDemodulate(enb, rxWaveform);
    [full_grid, grid_info] = lteOFDMDemodulateFull(enb, rxWaveform, 0.55);
    rxsubframe = full_grid(grid_info.activeIdx, :);
    % side_lobe = full_grid([grid_info.guardLowerIdx; grid_info.guardUpperIdx], :);
    [CSI_G1, CSI_G2, K_idx_G1, K_idx_G2] = fastDLCSIEstimate(enb, rxsubframe);

    % --- Step E: 频域 SFO 校正与精细相位校正 ---
    fLim_G1 = reshape(K_idx_G1(:,1) - N_carrier/2, [], 1, 1, 1);
    fLim_G2 = reshape(K_idx_G2(:,1) - N_carrier/2, [], 1, 1, 1);

    if sfIdx == 1
        staticCSI_G1 = CSI_G1(:, 1, :, :);
        staticCSI_G2 = CSI_G2(:, 1, :, :);
    end

    for t = 1:2
        % --- Group 1 精细校正 (Vectorized for rx_idx & tx_idx) ---
        csi1 = CSI_G1(:, t, :, :);
        % csi1 = csi1 ./ vecnorm(csi1);

        csiDiff1 = csi1 .* conj(staticCSI_G1);
        sampDiff1 = estimatePhaseSlopeFFT(csiDiff1) * nfft / N_carrier;
        sfoCorVec1 = exp(-2i*pi/nfft * sampDiff1 .* fLim_G1);
        phaseBias1 = angle(sum(csiDiff1 .* sfoCorVec1, 1));
        correctedCSI1 = csi1 .* sfoCorVec1 .* exp(-1i * phaseBias1);

        % 尺寸变为 [1, K, nRx, nTx]
        currentCSI1 = permute(correctedCSI1, [2, 1, 3, 4]);
        % filter 函数原生支持多维张量
        [staticCSI_row1, lpState_G1] = filter(lpB, lpA, currentCSI1, lpState_G1, 1);
        % staticCSI_row1 是 [1, K, nRx, nTx]。
        staticCSI_G1 = permute(staticCSI_row1, [2, 1, 3, 4]);
        % 顺便做静态消减
        CSI_G1(:, t, :, :) = correctedCSI1 - staticCSI_G1;
        % CSI_G1(:, t, :, :) = correctedCSI1;

        % --- Group 2 精细校正 (Vectorized for rx_idx & tx_idx) ---
        csi2 = CSI_G2(:, t, :, :);
        % csi2 = csi2 ./ vecnorm(csi2);

        csiDiff2 = csi2 .* conj(staticCSI_G2);
        sampDiff2 = estimatePhaseSlopeFFT(csiDiff2) * nfft / N_carrier;
        sfoCorVec2 = exp(-2i*pi/nfft * sampDiff2 .* fLim_G2);
        phaseBias2 = angle(sum(csiDiff2 .* sfoCorVec2, 1));
        correctedCSI2 = csi2 .* sfoCorVec2 .* exp(-1i * phaseBias2);

        currentCSI2 = permute(correctedCSI2, [2, 1, 3, 4]);
        [staticCSI_row2, lpState_G2] = filter(lpB, lpA, currentCSI2, lpState_G2, 1);
        staticCSI_G2 = permute(staticCSI_row2, [2, 1, 3, 4]);
        CSI_G2(:, t, :, :) = correctedCSI2 - staticCSI_G2;
        % CSI_G2(:, t, :, :) = correctedCSI2;
    end

    % 提取 SFO 用于时域漂移补偿
    symbolShift = round(mean([sampDiff1 sampDiff2], 'all'));
    % 由于 SFO 是累积的，将其转换为需要在下一次读取时补偿的整数样本数
    sfoIntCorrect = sfoIntCorrect - symbolShift;
    
    % --- Step F: 共用锚定重采样，递推二维相关与当前窗 2D-FFT ---
    currentCarrierOffsets = grid_info.freqAxis( ...
        grid_info.activeIdx(K_idx_G1(:, senseTx)));
    if isempty(anchoredResampler)
        % 必须使用实际射频频率；跨 DC 处不能只按等间距 CRS 行号推算。
        carrierOffsetsHz = currentCarrierOffsets;
        anchoredResampler = AnchoredSincResampler( ...
            fc+carrierOffsetsHz, fc, win_NSymb, ...
            resampleKernelTolerance, resampleGuardSamples, ...
            jointDopplerOrder+1);
        jointCorrelationState = Recursive2DAutocorrelation( ...
            fc+carrierOffsetsHz, crsSpacingHz, jointRangeOrder, ...
            jointDopplerOrder, jointForgettingFactor);
        fprintf(['Anchored sinc: N=%d, history=%d, Q=%d, near radius=%d, ' ...
            'kernel tolerance=%.1e\n'], win_NSymb, ...
            anchoredResampler.HistoryLength, anchoredResampler.ExpansionOrder, ...
            anchoredResampler.NearRadius, resampleKernelTolerance);
        fprintf(['Continuous joint correlation: range order=%d, Doppler order=%d, ' ...
            'lambda=%.6f\n'], jointRangeOrder, jointDopplerOrder, ...
            jointForgettingFactor);
    else
        assert(isequal(currentCarrierOffsets, carrierOffsetsHz), ...
            'CRS frequencies changed; the interpolation state must be reset.');
    end
    % 必须按列 push：二维相关的一次指数更新对应一个新慢时间样本。
    newCSIColumns = CSI_G1(:, :, senseRx, senseTx);
    for slowTimeIndex = 1:size(newCSIColumns, 2)
        anchoredResampler.push(newCSIColumns(:, slowTimeIndex));
        if anchoredResampler.SampleCount >= anchoredResampler.HistoryLength
            alignedLags = anchoredResampler.snapshot(jointDopplerOrder+1);
            jointCorrelationState.push(alignedLags);
        end
    end

    if anchoredResampler.SampleCount >= anchoredResampler.HistoryLength && ...
            anchoredResampler.SampleCount-jointLastSpectrumSample >= ...
            jointSpectrumUpdateSamples
        if ~isgraphics(rdFigure)
            break; % 关闭显示窗口即可结束这次试跑。
        end
        jointLastSpectrumSample = anchoredResampler.SampleCount;

        % 完整矩阵只供 2D-FFT；与 AR 相关共用同一个插值锚点。
        alignedCSI = anchoredResampler.snapshot();
        [rdPower, r_lim] = anchoredRangeDopplerFFT(alignedCSI, ...
            carrierOffsetsHz, grid_info.subcarrierSpacing, rdRangeFftLength, ...
            jointDopplerPoints, slowTimeSamplePeriod);
        r_mask = r_lim >= -rdRangeHalfSpan & r_lim < rdRangeHalfSpan;
        rd_mag = 10*log10(max(rdPower(r_mask, velocityOrder(v_mask)), realmin));
        finiteMagnitude = rd_mag(isfinite(rd_mag));
        if isempty(fftNoiseFloor) && any(rdPower(:) > 0) && ~isempty(finiteMagnitude)
            sortedMagnitude = sort(finiteMagnitude);
            fftNoiseFloor = sortedMagnitude(max(1, round(numel(sortedMagnitude)*0.10)));
            fftDisplayRange = [fftNoiseFloor-10 fftNoiseFloor+40];
        end
        if isempty(rdImage)
            rdImage = imagesc(rdAxes, v_lim(v_mask), r_lim(r_mask), rd_mag);
            set(rdAxes, 'YDir', 'normal');
            colormap(rdAxes, 'jet');
            colorbar(rdAxes);
            xlabel(rdAxes, 'Equivalent radial velocity (m/s)');
            ylabel(rdAxes, 'Equivalent range (m)');
        else
            set(rdImage, 'CData', rd_mag);
        end
        if ~isempty(fftNoiseFloor), clim(rdAxes, fftDisplayRange); end
        title(rdAxes, sprintf('Current-anchor 2D-FFT R-D (record progress %.3f s)', ...
            (rawSampleOffset+rawSamplesPerSubframe)/raw_sr));

        % 仅读取已连续累积的联合相关；求解/绘图不清空状态。
        if jointCorrelationState.SampleCount >= jointMinimumUpdates
            [jointMusicPower, musicEigenvalues, musicAppliedLoading, ...
                    musicCovarianceRcond] = ...
                jointMusicRangeDopplerSpectrum(jointCorrelationState.Correlation, ...
                jointRangeOrder, jointDopplerOrder, jointRangePoints, ...
                jointDopplerPoints, musicSignalCount, musicDiagonalLoading);
            jointDisplayPower = jointMusicPower( ...
                jointRangeDisplayOrder(jointRangeMask), ...
                velocityOrder(v_mask));
            jointMagnitude = 10*log10(max(jointDisplayPower / ...
                max(max(jointDisplayPower, [], 'all'), realmin), realmin));
            if isempty(jointImage)
                jointImage = imagesc(jointAxes, v_lim(v_mask), ...
                    jointRangeAxis(jointRangeMask), jointMagnitude);
                set(jointAxes, 'YDir', 'normal');
                colormap(jointAxes, 'jet');
                colorbar(jointAxes);
                xlabel(jointAxes, 'Equivalent radial velocity (m/s)');
                ylabel(jointAxes, 'Equivalent range (m)');
                % clim(jointAxes, [-45 0]);
            else
                set(jointImage, 'CData', jointMagnitude);
            end
            musicEigenGap = musicEigenvalues(musicSignalCount) / ...
                max(musicEigenvalues(musicSignalCount+1), eps);
            title(jointAxes, sprintf( ...
                ['Continuous 2-D MUSIC (D=%d, %d updates, eigengap %.2g, ' ...
                'loading %.3g, rcond %.2g)'], ...
                musicSignalCount, jointCorrelationState.SampleCount, ...
                musicEigenGap, musicAppliedLoading, musicCovarianceRcond));
        else
            title(jointAxes, sprintf( ...
                'Continuous joint 2-D MUSIC: warming up (%d/%d updates)', ...
                jointCorrelationState.SampleCount, jointMinimumUpdates));
        end
        drawnow limitrate;
    end
    
    % 更新帧号与子帧号
    current_NSubframe = current_NSubframe + 1;
    if current_NSubframe == 10
        current_NSubframe = 0;
        current_NFrame = mod(current_NFrame + 1, 1024);
    end

end

fprintf('Joint 2-D MUSIC and anchored 2D-FFT CSI extraction completed.\n');
