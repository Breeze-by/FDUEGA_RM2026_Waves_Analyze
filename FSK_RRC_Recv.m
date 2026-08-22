function result = FSK_RRC_Recv(varargin)
    recvCallTic = tic;
    recvStartEpochSec = posixtime(datetime('now', 'TimeZone', 'UTC'));
    cfgDefault = FSK_RRC_ProjectConfig();
    rxCfg = cfgDefault.rx;

    p = inputParser;
    addParameter(p, 'SourceName', rxCfg.SourceName);
    addParameter(p, 'RxRadioID', rxCfg.RxRadioID);
    addParameter(p, 'UseAGC', rxCfg.UseAGC);
    addParameter(p, 'AGCMode', rxCfg.AGCMode);
    addParameter(p, 'RxGain_dB', rxCfg.RxGain_dB);
    addParameter(p, 'CaptureSampleRateHz', rxCfg.CaptureSampleRateHz);
    addParameter(p, 'RxCenterFrequencyOffsetHz', rxCfg.RxCenterFrequencyOffsetHz);
    addParameter(p, 'RxRFBandwidthHz', rxCfg.RxRFBandwidthHz);
    addParameter(p, 'SamplesPerFrame', rxCfg.SamplesPerFrame);
    addParameter(p, 'WarmupFrames', rxCfg.WarmupFrames);
    addParameter(p, 'CaptureTimeSec', rxCfg.CaptureTimeSec);
    % 接收端只保留正式比赛的新解调链路：
    % 复数通道低通 → 正交鉴频 →（干扰波高斯滤波）→ 过零符号同步。
    addParameter(p, 'PreDemodChannelCutoffHz', []);
    addParameter(p, 'PreDemodChannelFilterOrder', 240);
    addParameter(p, 'QuadratureDemodGain', 1.5);
    addParameter(p, 'SymbolSyncLoopBandwidth', 0.005);
    addParameter(p, 'SymbolSyncDampingFactor', 1.0);
    addParameter(p, 'SymbolSyncDetectorGain', 1.0);
    addParameter(p, 'EnablePlutoRx', rxCfg.EnablePlutoRx);
    addParameter(p, 'ReusePlutoRx', false);
    addParameter(p, 'InputSamples', rxCfg.InputSamples);
    addParameter(p, 'ShowPlots', rxCfg.ShowPlots);
    % 仅供独立诊断工具保留通道滤波前的原始 Pluto IQ。默认关闭，避免
    % 正式比赛链路额外复制大块采样内存。
    addParameter(p, 'PreserveRawRxSamples', false);
    % Web 诊断只读观察器：在正式采集循环内抽取当前 Pluto 帧用于频谱显示。
    % 默认关闭，不改变正式比赛采集、解调或协议解析行为。
    addParameter(p, 'FrameObserverFcn', []);
    addParameter(p, 'FrameObserverIntervalSec', 0.15);
    addParameter(p, 'HeartbeatFcn', []);
    addParameter(p, 'HeartbeatIntervalSec', 0.1);
    addParameter(p, 'SkipProjectSetup', false);
    addParameter(p, 'UseThreadSafeIntegerResample', false);
    parse(p, varargin{:});
    opt = p.Results;
    % thread-based backgroundPool 禁止修改 MATLAB path。采集主线程已经执行
    % project_setup，后台解码窗口显式传入 SkipProjectSetup=true 并继承现有路径。
    persistent projectPrepared
    if ~logical(opt.SkipProjectSetup) && isempty(projectPrepared)
        project_setup();
        projectPrepared = true;
    end
    opt.AGCMode = local_normalize_agc_mode(opt.AGCMode);
    opt.PreDemodChannelCutoffHz = double(opt.PreDemodChannelCutoffHz);
    opt.PreDemodChannelFilterOrder = double(opt.PreDemodChannelFilterOrder);
    if ~isempty(opt.PreDemodChannelCutoffHz) && ...
            (~isscalar(opt.PreDemodChannelCutoffHz) || ...
            ~isfinite(opt.PreDemodChannelCutoffHz) || ...
            opt.PreDemodChannelCutoffHz <= 0)
        error('PreDemodChannelCutoffHz 必须为空或正数。');
    end
    if ~isscalar(opt.PreDemodChannelFilterOrder) || ...
            ~isfinite(opt.PreDemodChannelFilterOrder) || ...
            opt.PreDemodChannelFilterOrder <= 0 || ...
            mod(opt.PreDemodChannelFilterOrder, 2) ~= 0
        error('PreDemodChannelFilterOrder 必须是正偶数。');
    end
    opt.QuadratureDemodGain = double(opt.QuadratureDemodGain);
    if ~isscalar(opt.QuadratureDemodGain) || ...
            ~isfinite(opt.QuadratureDemodGain) || ...
            opt.QuadratureDemodGain <= 0
        error('QuadratureDemodGain 必须是正数。');
    end
    if ~isscalar(opt.SymbolSyncLoopBandwidth) || ...
            ~isfinite(double(opt.SymbolSyncLoopBandwidth)) || ...
            double(opt.SymbolSyncLoopBandwidth) <= 0
        error('SymbolSyncLoopBandwidth 必须是正数。');
    end
    if ~isscalar(opt.SymbolSyncDampingFactor) || ...
            ~isfinite(double(opt.SymbolSyncDampingFactor)) || ...
            double(opt.SymbolSyncDampingFactor) <= 0
        error('SymbolSyncDampingFactor 必须是正数。');
    end
    if ~isscalar(opt.SymbolSyncDetectorGain) || ...
            ~isfinite(double(opt.SymbolSyncDetectorGain)) || ...
            double(opt.SymbolSyncDetectorGain) <= 0
        error('SymbolSyncDetectorGain 必须是正数。');
    end
    opt.RxCenterFrequencyOffsetHz = double(opt.RxCenterFrequencyOffsetHz);
    if ~isscalar(opt.RxCenterFrequencyOffsetHz) || ~isfinite(opt.RxCenterFrequencyOffsetHz)
        error('RxCenterFrequencyOffsetHz 必须是有限标量。');
    end
    opt.PreserveRawRxSamples = logical(opt.PreserveRawRxSamples);
    opt.FrameObserverIntervalSec = max(0.05, double(opt.FrameObserverIntervalSec));
    usingDefaultCaptureSampleRate = any(strcmp(p.UsingDefaults, 'CaptureSampleRateHz'));

    % 非复用的手动调用仍维持原清理行为；正式信息波流程复用 Pluto 时避免每轮扫描、清理工作区。
    if ~opt.ReusePlutoRx
        close all;
        cleanup_pluto_workspace_objects();
    end

    rxRef = local_get_rx_reference(opt);
    S = rxRef.params;
    Fs = S.Fs;
    externalInput = ~isempty(opt.InputSamples);
    if externalInput && usingDefaultCaptureSampleRate
        captureFs = Fs;
    else
        captureFs = double(opt.CaptureSampleRateHz);
    end
    if isempty(captureFs) || ~isfinite(captureFs) || captureFs <= 0
        captureFs = Fs;
    end
    Rs = S.Rs;
    sps = S.sps;
    sourceName = string(S.sourceName);
    sourceCfg = get_gfsk_source_config(sourceName);
    if sourceCfg.waveType == "broadcast"
        demodFilterType = "none";
    else
        demodFilterType = "gaussian";
    end
    if isempty(opt.PreDemodChannelCutoffHz)
        % 各波形统一按官方占用带宽的一半设置复数通道低通：
        % 信息波 270 kHz，一级 470 kHz，二级 430 kHz，三级 125 kHz。
        opt.PreDemodChannelCutoffHz = sourceCfg.rfBandwidth / 2;
    end
    gaussianBT = sourceCfg.bt;
    gaussianSpan = sourceCfg.gaussianSpan;
    nominalFc = sourceCfg.fc;
    fc = nominalFc + opt.RxCenterFrequencyOffsetHz;
    rfBandwidthHz = local_get_source_rx_bandwidth_hz( ...
        sourceCfg.rxBandwidth, opt.RxRFBandwidthHz);

    fprintf("\n=== 接收配置 ===\n");
    fprintf("参考来源：静态波源配置\n");
    fprintf("当前源类型：%s\n", local_source_display_name(sourceName));
    fprintf("标称中心频点：%.3f MHz\n", nominalFc / 1e6);
    fprintf("硬件中心频点：%.3f MHz（偏移 %+.1f kHz）\n", ...
        fc / 1e6, opt.RxCenterFrequencyOffsetHz / 1e3);
    fprintf("Pluto 采集采样率：%.3f MHz\n", captureFs / 1e6);
    fprintf("Pluto RF 带宽：%.3f MHz\n", rfBandwidthHz / 1e6);
    fprintf("解码采样率：%.3f MHz\n", Fs / 1e6);
    fprintf("符号率/比特率：%.3f kbit/s\n", Rs / 1e3);
    fprintf("每符号采样点：%d\n", sps);
    fprintf("鉴频后滤波：%s\n", demodFilterType);
    fprintf("鉴频前复数低通：cutoff=%.3f kHz，order=%d\n", ...
        opt.PreDemodChannelCutoffHz / 1e3, opt.PreDemodChannelFilterOrder);
    fprintf("正交鉴频增益：%.6g\n", opt.QuadratureDemodGain);
    fprintf("符号同步：zero_crossing（正式唯一算法）\n");
    if externalInput
        plutoSetupElapsedSec = 0;
        captureElapsedSec = 0;
        r = opt.InputSamples(:);
        captureStartEpochSec = recvStartEpochSec;
        fprintf("输入方式：外部 IQ 样本\n");
        fprintf("样本点数：%d\n", numel(r));
        local_call_heartbeat(opt.HeartbeatFcn);
    else
        if ~opt.EnablePlutoRx
            error('When EnablePlutoRx=false, InputSamples must be provided.');
        end

        numFramesToGrab = max(1, ceil(opt.CaptureTimeSec * captureFs / opt.SamplesPerFrame));
        fprintf("输入方式：Pluto 实时采集\n");
        fprintf("预计采集时长：%.3f s\n", numFramesToGrab * opt.SamplesPerFrame / captureFs);
        fprintf("预计采集帧数：%d\n", numFramesToGrab);

        plutoSetupTic = tic;
        radioCtx = resolve_pluto_radio_id(opt.RxRadioID, "rx");
        resolvedRadioID = radioCtx.resolvedRadioID;
        if radioCtx.usedDefaultRoute
            fprintf("使用默认 Pluto 接收地址：%s\n", resolvedRadioID);
        end

        reusableCfg = struct( ...
            'radioID', string(resolvedRadioID), ...
            'centerFrequency', double(fc), ...
            'sampleRate', double(captureFs), ...
            'samplesPerFrame', double(opt.SamplesPerFrame), ...
            'useAGC', logical(opt.UseAGC), ...
            'agcMode', opt.AGCMode, ...
            'gainDB', double(opt.RxGain_dB), ...
            'rfBandwidthHz', double(rfBandwidthHz));
        receiverReused = false;
        if opt.ReusePlutoRx
            [rx, receiverReused] = reusable_pluto_rx("acquire", reusableCfg);
        elseif opt.UseAGC
            rx = sdrrx('Pluto', ...
                'RadioID', char(resolvedRadioID), ...
                'CenterFrequency', fc, ...
                'BasebandSampleRate', captureFs, ...
                'SamplesPerFrame', opt.SamplesPerFrame, ...
                'OutputDataType', 'double', ...
                'GainSource', local_agc_gain_source(opt.AGCMode));
        else
            rx = sdrrx('Pluto', ...
                'RadioID', char(resolvedRadioID), ...
                'CenterFrequency', fc, ...
                'BasebandSampleRate', captureFs, ...
                'SamplesPerFrame', opt.SamplesPerFrame, ...
                'OutputDataType', 'double', ...
                'GainSource', 'Manual', ...
                'Gain', opt.RxGain_dB);
        end
        if ~opt.ReusePlutoRx
            rxCleanup = onCleanup(@() local_release_pluto_rx(rx));
        end

        if ~receiverReused
            rxInfo = info(rx);
            disp(rxInfo);
        else
            fprintf("复用已连接的 Pluto RX，不重复初始化和预热。\n");
        end

        if ~receiverReused
            for k = 1:opt.WarmupFrames
                rx();
                local_call_heartbeat(opt.HeartbeatFcn);
            end
            apply_pluto_rx_rf_bandwidth(rx, resolvedRadioID, rfBandwidthHz);
        end
        plutoSetupElapsedSec = toc(plutoSetupTic);

        captureStartEpochSec = posixtime(datetime('now', 'TimeZone', 'UTC'));
        captureTic = tic;
        r = complex(zeros(opt.SamplesPerFrame * numFramesToGrab, 1));
        pWrite = 1;
        lastHeartbeatTic = tic;
        lastFrameObserverTic = [];
        for k = 1:numFramesToGrab
            frame = rx();
            if ~isempty(opt.FrameObserverFcn) && ...
                    (isempty(lastFrameObserverTic) || ...
                    toc(lastFrameObserverTic) >= opt.FrameObserverIntervalSec)
                local_call_frame_observer(opt.FrameObserverFcn, frame, captureFs);
                lastFrameObserverTic = tic;
            end
            L = numel(frame);
            r(pWrite:pWrite + L - 1) = frame(:);
            pWrite = pWrite + L;
            if isempty(lastHeartbeatTic) || toc(lastHeartbeatTic) >= opt.HeartbeatIntervalSec
                local_call_heartbeat(opt.HeartbeatFcn);
                lastHeartbeatTic = tic;
            end
        end
        r = r(1:pWrite - 1);
        captureElapsedSec = toc(captureTic);

        if opt.ReusePlutoRx
            clear rx;
        else
            clear rxCleanup rx;
        end
    end

    local_call_heartbeat(opt.HeartbeatFcn);

    if opt.PreserveRawRxSamples
        rawRxSamples = r;
    else
        rawRxSamples = complex(zeros(0, 1));
    end

    decodeTic = tic;
    [r, m_hat_raw, m_hat, bitMetricStream, best] = ...
        local_decode_capture(r, captureFs, Fs, opt, S, sps, demodFilterType);
    decodeElapsedSec = toc(decodeTic);
    totalElapsedSec = toc(recvCallTic);
    decodeCompleteEpochSec = posixtime(datetime('now', 'TimeZone', 'UTC'));

    captureDurationSec = numel(r) / Fs;
    expectedCycleCountRaw = captureDurationSec / S.cycleDurationSec;
    expectedCycleCount = floor(expectedCycleCountRaw);
    expectedOtaPacketCount = floor(expectedCycleCountRaw * S.otaPacketCountPerCycle);
    expectedProtocolFrameCount = floor(expectedCycleCountRaw * S.protocolFrameCountPerCycle);
    packetLossCount = max(expectedOtaPacketCount - best.validPacketCount, 0);
    frameLossCount = max(expectedProtocolFrameCount - best.validFrameCount, 0);
    packetSuccessRate = min(best.validPacketCount / max(expectedOtaPacketCount, 1), 1);
    frameSuccessRate = min(best.validFrameCount / max(expectedProtocolFrameCount, 1), 1);

    fprintf("\n=== 接收统计 ===\n");
    fprintf("射频带宽：%.3f MHz\n", rfBandwidthHz / 1e6);
    if demodFilterType == "gaussian"
        fprintf("解调滤波：Gaussian BT=%.2f span=%d symbols\n", ...
            gaussianBT, gaussianSpan);
    else
        fprintf("鉴频后滤波：无（直接进入符号同步）\n");
    end
    fprintf("实际采集时长：%.3f s\n", captureDurationSec);
    fprintf("单周期时长：%.3f ms\n", S.cycleDurationSec * 1e3);
    fprintf("折算周期数：%.3f\n", expectedCycleCountRaw);
    fprintf("按完整周期统计：%d\n", expectedCycleCount);
    fprintf("期望 OTA 包数：%d\n", expectedOtaPacketCount);
    fprintf("有效 OTA 包数：%d\n", best.validPacketCount);
    fprintf("OTA 成功率：%.3f\n", packetSuccessRate);
    fprintf("OTA 丢包数：%d\n", packetLossCount);
    fprintf("期望协议帧数：%d\n", expectedProtocolFrameCount);
    fprintf("有效协议帧数：%d\n", best.validFrameCount);
    fprintf("协议帧成功率：%.3f\n", frameSuccessRate);
    fprintf("协议帧丢失数：%d\n", frameLossCount);
    fprintf("最优比特移位：%d\n", best.bitShift);
    fprintf("耗时：Pluto初始化=%.3f s，采集=%.3f s，解码=%.3f s，总计=%.3f s\n", ...
        plutoSetupElapsedSec, captureElapsedSec, decodeElapsedSec, totalElapsedSec);
    fprintf("解码候选：Access筛选后=%d，实际解析=%d\n", ...
        best.accessCandidateCount, best.evaluatedCandidateCount);

    if ~isempty(best.frames)
        fprintf("\n=== 协议帧示例 ===\n");
        local_print_frame_examples(best.frames, min(numel(best.frames), 5));
    else
        warning("No valid protocol frames detected. Check center frequency, gain, RF bandwidth, antenna path, and capture duration.");
    end

    if opt.ShowPlots
        local_show_rx_plots(r, m_hat, bitMetricStream, best, Fs);
    end

    result = struct( ...
        'referenceMode', rxRef.mode, ...
        'sourceName', sourceName, ...
        'params', S, ...
        'captureDurationSec', captureDurationSec, ...
        'expectedCycleCountRaw', expectedCycleCountRaw, ...
        'expectedCycleCount', expectedCycleCount, ...
        'expectedOtaPacketCount', expectedOtaPacketCount, ...
        'expectedProtocolFrameCount', expectedProtocolFrameCount, ...
        'packetLossCount', packetLossCount, ...
        'frameLossCount', frameLossCount, ...
        'packetSuccessRate', packetSuccessRate, ...
        'frameSuccessRate', frameSuccessRate, ...
        'captureSampleRateHz', captureFs, ...
        'decodeSampleRateHz', Fs, ...
        'nominalCenterFrequencyHz', nominalFc, ...
        'hardwareCenterFrequencyHz', fc, ...
        'rxCenterFrequencyOffsetHz', opt.RxCenterFrequencyOffsetHz, ...
        'rfBandwidthHz', rfBandwidthHz, ...
        'demodFilterType', demodFilterType, ...
        'gaussianBT', gaussianBT, ...
        'gaussianSpan', gaussianSpan, ...
        'preDemodChannelCutoffHz', double(opt.PreDemodChannelCutoffHz), ...
        'preDemodChannelFilterOrder', double(opt.PreDemodChannelFilterOrder), ...
        'quadratureDemodGain', opt.QuadratureDemodGain, ...
        'symbolSyncType', "zero_crossing", ...
        'symbolSyncLoopBandwidth', double(opt.SymbolSyncLoopBandwidth), ...
        'symbolSyncDampingFactor', double(opt.SymbolSyncDampingFactor), ...
        'symbolSyncDetectorGain', double(opt.SymbolSyncDetectorGain), ...
        'plutoSetupElapsedSec', plutoSetupElapsedSec, ...
        'captureElapsedSec', captureElapsedSec, ...
        'decodeElapsedSec', decodeElapsedSec, ...
        'totalElapsedSec', totalElapsedSec, ...
        'recvStartEpochSec', recvStartEpochSec, ...
        'captureStartEpochSec', captureStartEpochSec, ...
        'decodeCompleteEpochSec', decodeCompleteEpochSec, ...
        'rawRxSamples', rawRxSamples, ...
        'rxSamples', r, ...
        'm_hat_raw', m_hat_raw, ...
        'm_hat', m_hat, ...
        'bitMetricStream', bitMetricStream, ...
        'best', best);
end

function agcMode = local_normalize_agc_mode(value)
    agcMode = lower(strtrim(string(value)));
    if agcMode == "slow_attack"
        agcMode = "slow";
    elseif agcMode == "fast_attack"
        agcMode = "fast";
    end
    if ~ismember(agcMode, ["slow", "fast"])
        error('AGCMode 仅支持 slow 或 fast，当前值：%s。', agcMode);
    end
end

function gainSource = local_agc_gain_source(agcMode)
    if agcMode == "fast"
        gainSource = 'AGC Fast Attack';
    else
        gainSource = 'AGC Slow Attack';
    end
end

function local_call_heartbeat(heartbeatFcn)
    if isempty(heartbeatFcn)
        return;
    end
    try
        heartbeatFcn();
    catch ME
        fprintf('Heartbeat callback failed: %s\n', ME.message);
    end
end

function local_call_frame_observer(observerFcn, frame, sampleRateHz)
    try
        observerFcn(frame(:), sampleRateHz);
    catch ME
        fprintf('Frame observer callback failed: %s\n', ME.message);
    end
end

function local_release_pluto_rx(rx)
    if isempty(rx)
        return;
    end

    try
        release(rx);
    catch ME
        fprintf('Pluto RX release failed: %s\n', ME.message);
    end
end

function rxRef = local_get_rx_reference(opt)
    sourceName = string(opt.SourceName);
    if strlength(strtrim(sourceName)) == 0
        error("接收端必须明确知道当前要接收的波源，请在 FSK_RRC_ProjectConfig.rx.SourceName 或调用参数 SourceName 中设置。");
    end

    persistent cachedSourceName cachedParams
    if isempty(cachedSourceName) || cachedSourceName ~= sourceName
        cachedParams = build_gfsk_rx_reference(sourceName);
        cachedSourceName = sourceName;
    end
    params = cachedParams;
    rxRef = struct('mode', "static_source_config", 'params', params);
end

function rfBandwidthHz = local_get_source_rx_bandwidth_hz(sourceRxBandwidthHz, overrideHz)
    if nargin >= 2 && ~isempty(overrideHz) && isfinite(double(overrideHz)) && double(overrideHz) > 0
        rfBandwidthHz = double(overrideHz);
        return;
    end
    rfBandwidthHz = double(sourceRxBandwidthHz);
end

function [r, mHatRaw, mHat, bitMetricStream, best] = local_decode_capture( ...
        rawSamples, captureFs, decodeFs, opt, reference, sps, demodFilterType)
    r = rawSamples(:);
    if opt.RxCenterFrequencyOffsetHz ~= 0
        sampleIndex = (0:numel(r)-1).';
        r = r .* exp(1j * 2*pi * opt.RxCenterFrequencyOffsetHz * ...
            sampleIndex / captureFs);
    end
    if abs(captureFs - decodeFs) > max(1, 1e-9 * decodeFs)
        r = local_resample_to_decode_rate( ...
            r, captureFs, decodeFs, logical(opt.UseThreadSafeIntegerResample));
    end

    normalizedCutoff = opt.PreDemodChannelCutoffHz / (decodeFs / 2);
    if normalizedCutoff >= 1
        error('鉴频前通道低通截止频率必须小于 Nyquist 频率。');
    end
    % 与 GNU Radio firdes.low_pass 的默认 Hamming FIR 对齐：
    % Fs=1 MHz、cutoff=270 kHz、transition=10 kHz 时为 241 taps。
    channelTaps = fir1( ...
        opt.PreDemodChannelFilterOrder, normalizedCutoff, ...
        hamming(opt.PreDemodChannelFilterOrder + 1));
    r = filter(channelTaps, 1, r);
    discriminatorHz = fsk_discriminator_hz(r, decodeFs);
    % GNU Radio Quadrature Demod：gain * angle(x[n] * conj(x[n-1]))。
    mHatRaw = discriminatorHz * (2*pi / decodeFs) * opt.QuadratureDemodGain;
    if demodFilterType == "gaussian"
        sourceCfg = get_gfsk_source_config(reference.sourceName);
        gaussianBT = sourceCfg.bt;
        gaussianSpan = sourceCfg.gaussianSpan;
        hGaussian = make_gaussian_taps(gaussianBT, gaussianSpan, sps);
        % 干扰波在鉴频后通过高斯 FIR，再进入同一套过零符号同步。
        mHat = filter(hGaussian, 1, mHatRaw);
        bitMetricStream = mHat;
    else
        mHat = mHatRaw;
        bitMetricStream = mHatRaw;
    end
    decodeRef = reference;
    decodeRef.useExpectedPayloadMatching = false;
    syncScale = sqrt(mean(abs(bitMetricStream).^2));
    if ~isfinite(syncScale) || syncScale <= eps
        syncScale = 1;
    end
    syncInput = real(bitMetricStream) / syncScale;
    symbolSync = comm.SymbolSynchronizer( ...
        'Modulation', 'PAM/PSK/QAM', ...
        'TimingErrorDetector', 'Zero-Crossing (decision-directed)', ...
        'SamplesPerSymbol', sps, ...
        'DampingFactor', double(opt.SymbolSyncDampingFactor), ...
        'NormalizedLoopBandwidth', double(opt.SymbolSyncLoopBandwidth), ...
        'DetectorGain', double(opt.SymbolSyncDetectorGain));
    synchronizedMetrics = symbolSync(syncInput);
    release(symbolSync);
    bitMetricStream = synchronizedMetrics(:);
    best = decode_gfsk_symbol_stream(bitMetricStream, decodeRef);
    best.symbolSyncInputScale = syncScale;
    best.symbolSyncOutputCount = numel(bitMetricStream);
end

function y = local_resample_to_decode_rate(x, captureFs, decodeFs, useThreadSafeIntegerResample)
    x = x(:);
    [p, q] = rat(decodeFs / captureFs, 1e-9);

    if p == q
        y = x;
        return;
    end

    if useThreadSafeIntegerResample && p == 1 && q >= 2 && ...
            abs(captureFs / decodeFs - q) < 1e-9
        % backgroundPool 禁止调用 resample 内部的 upfirdnmex。整数抽取时先用
        % 纯 MATLAB FIR 抑制新 Nyquist 频率以上的混叠，再按 q 倍抽取。
        antiAliasOrder = 96;
        normalizedCutoff = 0.90 / q;
        antiAliasTaps = fir1(antiAliasOrder, normalizedCutoff, ...
            hamming(antiAliasOrder + 1));
        filtered = filter(antiAliasTaps, 1, x);
        y = filtered(1:q:end);
    elseif exist('resample', 'file') == 2
        y = resample(x, p, q);
    elseif q > 1 && p == 1 && abs(captureFs / decodeFs - q) < 1e-9
        y = x(1:q:end);
    else
        error('resample function is required for %.3f MHz -> %.3f MHz conversion.', ...
            captureFs / 1e6, decodeFs / 1e6);
    end
end

function textOut = local_source_display_name(sourceName)
    cfg = get_gfsk_source_config(sourceName);
    textOut = cfg.displayName;
end

function local_print_frame_examples(frames, maxCount)
    printed = 0;
    for k = 1:numel(frames)
        fr = frames(k).result;
        fprintf("帧 %d\n", printed + 1);
        fprintf("  序号：%d\n", fr.seq);
        fprintf("  命令码：0x%04X\n", fr.cmdId);
        fprintf("  类型：%s\n", local_cmd_type_text(fr.type));
        fprintf("  内容：%s\n", protocol_frame_to_text(fr));
        printed = printed + 1;
        if printed >= maxCount
            break;
        end
    end
end

function textOut = local_cmd_type_text(typeName)
    switch string(typeName)
        case "broadcast_positions"
            textOut = "位置信息";
        case "broadcast_hp"
            textOut = "血量信息";
        case "broadcast_projectiles"
            textOut = "弹量信息";
        case "broadcast_economy"
            textOut = "经济与增益点状态";
        case "broadcast_buffs"
            textOut = "机器人增益";
        case "jammer_key"
            textOut = "干扰密钥";
        otherwise
            textOut = char(string(typeName));
    end
end

function local_show_rx_plots(r, m_hat, bitMetricStream, best, Fs)
    t = (0:numel(r)-1).' / Fs;
    Nshow = min(numel(r), round(0.01 * Fs));
    ts = t(1:Nshow);

    figure('Name', '接收 IQ');
    subplot(2,1,1);
    plot(ts * 1e3, real(r(1:Nshow)), 'LineWidth', 1.0); grid on; hold on;
    plot(ts * 1e3, imag(r(1:Nshow)), 'LineWidth', 1.0);
    hold off;
    xlabel('时间 (ms)'); ylabel('幅度');
    legend('I', 'Q', 'Location', 'best');
    title('接收 IQ 波形');

    subplot(2,1,2);
    M = min(numel(r), 5000);
    plot(real(r(1:M)), imag(r(1:M)), '.'); axis equal; grid on;
    xlabel('I'); ylabel('Q');
    title('接收 IQ 星座');

    figure('Name', '接收处理过程');
    subplot(3,2,1);
    [fAxisRx, psdRx] = simple_spectrum_db(r, Fs, 8192);
    plot(fAxisRx / 1e3, psdRx, 'LineWidth', 1.1); grid on;
    xlabel('频率 (kHz)'); ylabel('幅度 (dB)');
    title('接收频谱');

    subplot(3,2,2);
    plot(m_hat(1:min(5000,end)), 'LineWidth', 1.1); grid on;
    xlabel('采样点'); ylabel('归一化频偏');
    title('鉴频输出');

    subplot(3,2,3);
    plot(bitMetricStream(1:min(5000,end)), 'LineWidth', 1.1); grid on;
    xlabel('采样点'); ylabel('比特判决统计量');
    title('判决统计量');

    subplot(3,2,4);
    nShowBits = min(200, numel(best.bitsHat));
    stairs(best.bitsHat(1:nShowBits), 'LineWidth', 1.2); grid on;
    xlabel('比特索引'); ylabel('判决值');
    ylim([-0.2 1.2]);
    title(sprintf('恢复比特流 | bitShift=%d', best.bitShift));

    subplot(3,2,5);
    if ~isempty(best.otaPackets)
        starts = [best.otaPackets.startIndex];
        stem(starts, ones(size(starts)), 'filled'); grid on;
        xlabel('字节流起始位置'); ylabel('命中');
        title(sprintf('有效 OTA 包位置 | 数量=%d', numel(best.otaPackets)));
        ylim([0 1.5]);
    else
        text(0.1, 0.5, '未找到有效 OTA 包', 'FontSize', 12);
        axis off;
    end

    subplot(3,2,6);
    if ~isempty(best.frames)
        cmdIds = arrayfun(@(x) double(x.result.cmdId), best.frames);
        stem(cmdIds, 'filled'); grid on;
        xlabel('协议帧序号'); ylabel('cmdId');
        title(sprintf('有效协议帧命令码序列 | 数量=%d', numel(best.frames)));
    else
        text(0.1, 0.5, '未找到有效协议帧', 'FontSize', 12);
        axis off;
    end
end
