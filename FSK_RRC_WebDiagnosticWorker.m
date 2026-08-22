function FSK_RRC_WebDiagnosticWorker(varargin)
    % Web 双 Pluto 诊断后端的单路 MATLAB worker。
    %
    % 每个进程只占用一块 Pluto，循环调用正式 FSK_RRC_Recv。结果压缩成
    % JSON 快照供本机 Web 服务读取；不监听比赛状态，不发送任何业务 UDP。
    project_setup();

    cfg = FSK_RRC_ProjectConfig();
    p = inputParser;
    addParameter(p, 'Channel', "A");
    addParameter(p, 'SourceName', cfg.rx.SourceName);
    addParameter(p, 'RxRadioID', cfg.rx.RxRadioID);
    addParameter(p, 'OutputPath', "");
    addParameter(p, 'StopPath', "");
    parse(p, varargin{:});
    opt = local_normalize_options(p.Results);

    sourceCfg = get_gfsk_source_config(opt.SourceName);
    reusable_pluto_rx("release");
    cleanupObj = onCleanup(@() reusable_pluto_rx("release"));
    iteration = 0;
    cumulative = struct('validPackets', 0, 'expectedPackets', 0, ...
        'validFrames', 0, 'expectedFrames', 0, 'errors', 0);
    startTic = tic;

    local_write_snapshot(opt.OutputPath, struct( ...
        'channel', opt.Channel, 'state', "starting", ...
        'sourceName', opt.SourceName, 'radioID', opt.RxRadioID, ...
        'updatedUnixSec', posixtime(datetime('now', 'TimeZone', 'UTC'))));

    if isfile(opt.StopPath)
        local_write_snapshot(opt.OutputPath, struct( ...
            'channel', opt.Channel, 'state', "stopped", ...
            'sourceName', opt.SourceName, 'radioID', opt.RxRadioID, ...
            'iteration', 0, 'errorCount', 0, ...
            'updatedUnixSec', posixtime(datetime('now', 'TimeZone', 'UTC'))));
        return;
    end

    if sourceCfg.waveType == "broadcast"
        local_run_continuous_info(opt, sourceCfg, cumulative, startTic);
        return;
    end

    while ~isfile(opt.StopPath)
        iteration = iteration + 1;
        try
            % 保持与正式 FSK_RRC_AutoMatchUdp 相同的正式接收参数。测试专用
            % 开关只额外保留通道滤波前 IQ，不改变任何解调与协议判定。
            evalc("result = FSK_RRC_Recv(" + ...
                "'SourceName', char(opt.SourceName), " + ...
                "'RxRadioID', char(opt.RxRadioID), " + ...
                "'UseAGC', true, " + ...
                "'AGCMode', 'fast', " + ...
                "'CaptureTimeSec', 1.5, " + ...
                "'ReusePlutoRx', true, " + ...
                "'PreserveRawRxSamples', true, " + ...
                "'FrameObserverFcn', @(frame, sampleRateHz) " + ...
                    "local_publish_spectrum_snapshot(opt, sourceCfg, frame, sampleRateHz), " + ...
                "'FrameObserverIntervalSec', 0.15, " + ...
                "'ShowPlots', false);");

            cumulative.validPackets = cumulative.validPackets + result.best.validPacketCount;
            cumulative.expectedPackets = cumulative.expectedPackets + result.expectedOtaPacketCount;
            cumulative.validFrames = cumulative.validFrames + result.best.validFrameCount;
            cumulative.expectedFrames = cumulative.expectedFrames + result.expectedProtocolFrameCount;
            snapshot = local_build_snapshot(opt, sourceCfg, result, cumulative, iteration, toc(startTic));
            local_write_snapshot(opt.OutputPath, snapshot);
        catch ME
            cumulative.errors = cumulative.errors + 1;
            snapshot = struct( ...
                'channel', opt.Channel, 'state', "error", ...
                'sourceName', opt.SourceName, 'radioID', opt.RxRadioID, ...
                'iteration', iteration, 'errorCount', cumulative.errors, ...
                'error', string(ME.message), ...
                'updatedUnixSec', posixtime(datetime('now', 'TimeZone', 'UTC')));
            local_write_snapshot(opt.OutputPath, snapshot);
            fprintf(2, '[WEB_DIAGNOSTIC] channel=%s iteration=%d error=%s\n', ...
                opt.Channel, iteration, ME.message);
            pause(0.25);
        end
    end

    local_write_snapshot(opt.OutputPath, struct( ...
        'channel', opt.Channel, 'state', "stopped", ...
        'sourceName', opt.SourceName, 'radioID', opt.RxRadioID, ...
        'iteration', iteration, 'errorCount', cumulative.errors, ...
        'updatedUnixSec', posixtime(datetime('now', 'TimeZone', 'UTC'))));
end

function local_publish_spectrum_snapshot(opt, sourceCfg, frame, sampleRateHz)
    % 仅发布正式采集循环当前帧的频谱，不做解调和协议判定。
    % 高频预览只取末尾 2048 点做单次 FFT，避免 Welch 重叠计算
    % 阻塞 Pluto 的正式采样循环。
    [psdDb, fAxis] = local_quick_spectrum(frame(:), sampleRateHz, 2048);
    psdRelative = psdDb - max(psdDb);
    indexes = unique(round(linspace(1, numel(fAxis), min(720, numel(fAxis)))));
    snapshot = struct( ...
        'channel', opt.Channel, 'state', "spectrum", ...
        'sourceName', opt.SourceName, 'sourceDisplayName', sourceCfg.displayName, ...
        'waveType', sourceCfg.waveType, 'radioID', opt.RxRadioID, ...
        'updatedUnixSec', posixtime(datetime('now', 'TimeZone', 'UTC')), ...
        'hardwareCenterMHz', sourceCfg.fc / 1e6, ...
        'formalBandwidthKHz', sourceCfg.rfBandwidth / 1e3, ...
        'spectrumMHz', reshape((sourceCfg.fc + fAxis(indexes)) / 1e6, 1, []), ...
        'spectrumDb', reshape(psdRelative(indexes), 1, []));
    % 频谱和完整解析结果分文件发布，防止 150 ms 频谱快照
    % 覆盖 1.5 s 正式窗口刚解出的密钥。
    local_write_snapshot(opt.OutputPath + ".spectrum", snapshot);
end

function [spectrumDb, fAxis] = local_quick_spectrum(frame, sampleRateHz, nfft)
    frame = frame(:);
    sampleCount = min(numel(frame), nfft);
    segment = frame(end-sampleCount+1:end);
    segment = segment - mean(segment);
    if sampleCount > 1
        segment = segment .* hann(sampleCount);
    end
    transformed = fftshift(fft(segment, nfft));
    spectrumDb = 20 * log10(max(abs(transformed), eps));
    fAxis = ((-nfft/2):(nfft/2-1)).' * (sampleRateHz / nfft);
end

function local_run_continuous_info(opt, sourceCfg, cumulative, startTic)
    % 信息波严格复用正式比赛的连续采集、多 worker、250 ms 重叠窗口链路。
    projectCfg = FSK_RRC_ProjectConfig();
    action = struct('sourceName', opt.SourceName, 'rxRadioID', opt.RxRadioID);
    streamOpt = struct( ...
        'CaptureSampleRateHz', projectCfg.rx.InfoCaptureSampleRateHz, ...
        'InfoCaptureSampleRateHz', projectCfg.rx.InfoCaptureSampleRateHz, ...
        'SamplesPerFrame', projectCfg.rx.SamplesPerFrame, ...
        'InfoStreamDecodeWindowSec', 0.25, ...
        'InfoStreamDecodeStrideSec', 0.10, ...
        'InfoStreamRingBufferSec', 1.0, ...
        'InfoStreamMaxPendingWindows', 64, ...
        'InfoStreamWorkerCount', 2, ...
        'InfoCenterFrequencyOffsetHz', projectCfg.rx.RxCenterFrequencyOffsetHz, ...
        'RxRFBandwidthHz', projectCfg.rx.RxRFBandwidthHz, ...
        'InfoPreDemodChannelCutoffHz', 270e3, ...
        'InfoPreDemodChannelFilterOrder', 240, ...
        'InfoQuadratureDemodGain', 1.5, ...
        'InfoSymbolSyncLoopBandwidth', 0.005, ...
        'InfoSymbolSyncDampingFactor', 1.0, ...
        'InfoSymbolSyncDetectorGain', 1.0, ...
        'UseAGC', true, 'AGCMode', "fast", ...
        'RxGain_dB', projectCfg.rx.RxGain_dB, ...
        'WarmupFrames', projectCfg.rx.WarmupFrames);
    receiver = InfoWaveContinuousReceiver(action, streamOpt);
    receiverCleanup = onCleanup(@() receiver.stop());
    latestFrame = complex(zeros(0, 1));
    lastSpectrumPublishTic = [];
    iteration = 0;
    formalFilterState = struct( ...
        'infoCmdProcessedWindowEnd', zeros(5, 1), ...
        'infoCmdHasIdentity', false(5, 1), ...
        'infoCmdLastAcceptedSeq', zeros(5, 1, 'uint8'), ...
        'infoCmdPayloads', zeros(95, 1, 'uint8'), ...
        'infoDuplicateDropCount', 0, ...
        'infoStaleWindowDropCount', 0);
    infoCachedUpdates = cell(1, 5);
    infoRateTimes = cell(1, 5);
    infoTotalCounts = zeros(1, 5);
    rateWindowSec = 3.0;
    while ~isfile(opt.StopPath)
        [records, ~, frame] = receiver.step();
        if ~isempty(frame)
            % 只保留当前 25 ms Pluto 帧用于展示。旧实现每帧整体
            % 搬移 0.5 s double IQ 环形数组，会阻塞正式连续采集。
            latestFrame = frame(:);
            if isempty(lastSpectrumPublishTic) || ...
                    toc(lastSpectrumPublishTic) >= 0.15
                local_publish_spectrum_snapshot( ...
                    opt, sourceCfg, latestFrame, streamOpt.CaptureSampleRateHz);
                lastSpectrumPublishTic = tic;
            end
        end
        for recordIndex = 1:numel(records)
            decoded = records(recordIndex).decoded;
            if ~decoded.ok
                cumulative.errors = cumulative.errors + 1;
                continue;
            end
            iteration = iteration + 1;
            [formalFilterState, acceptedUpdates] = filter_info_wave_updates( ...
                formalFilterState, decoded.updates, records(recordIndex).windowEndSample);
            updateTime = toc(startTic);
            for updateIndex = 1:numel(acceptedUpdates)
                cmdIndex = acceptedUpdates(updateIndex).index;
                offsets = [1 25 37 47 55];
                lengths = [24 12 10 8 41];
                offset = offsets(cmdIndex);
                formalFilterState.infoCmdPayloads(offset:offset+lengths(cmdIndex)-1) = ...
                    uint8(acceptedUpdates(updateIndex).dataBytes(:));
                infoCachedUpdates{cmdIndex} = acceptedUpdates(updateIndex);
                infoRateTimes{cmdIndex}(end+1) = updateTime;
                infoTotalCounts(cmdIndex) = infoTotalCounts(cmdIndex) + 1;
            end
            infoRates = zeros(1, 5);
            cachedUpdates = decoded.updates([]);
            for cmdIndex = 1:5
                infoRateTimes{cmdIndex} = infoRateTimes{cmdIndex}( ...
                    infoRateTimes{cmdIndex} >= updateTime - rateWindowSec);
                infoRates(cmdIndex) = numel(infoRateTimes{cmdIndex}) / ...
                    max(min(rateWindowSec, updateTime), eps);
                if ~isempty(infoCachedUpdates{cmdIndex})
                    cachedUpdates(end+1) = infoCachedUpdates{cmdIndex}; %#ok<AGROW>
                end
            end
            expectedPackets = 23; % 250 ms 正式窗口约 2.5 个周期，每周期 10 个 OTA 包。
            expectedFrames = 12;  % 每周期 5 个信息波协议帧。
            cumulative.validPackets = cumulative.validPackets + decoded.validPacketCount;
            cumulative.expectedPackets = cumulative.expectedPackets + expectedPackets;
            cumulative.validFrames = cumulative.validFrames + decoded.validFrameCount;
            cumulative.expectedFrames = cumulative.expectedFrames + expectedFrames;
            if isempty(latestFrame)
                continue;
            end
            pseudo = local_make_info_result(latestFrame, ...
                streamOpt.CaptureSampleRateHz, sourceCfg, decoded, recordIndex, ...
                expectedPackets, expectedFrames, cachedUpdates, infoRates, infoTotalCounts);
            snapshot = local_build_snapshot(opt, sourceCfg, pseudo, ...
                cumulative, iteration, toc(startTic), true);
            snapshot.receiveMode = "formal_continuous_info";
            local_write_snapshot(opt.OutputPath, snapshot);
        end
        pause(0.001);
    end
end

function result = local_make_info_result(raw, sampleRateHz, sourceCfg, decoded, ...
        recordIndex, expectedPackets, expectedFrames, cachedUpdates, infoRates, infoTotalCounts)
    packetRate = min(decoded.validPacketCount / max(expectedPackets, 1), 1);
    frameRate = min(decoded.validFrameCount / max(expectedFrames, 1), 1);
    result = struct( ...
        'rawRxSamples', raw(:), 'rxSamples', raw(:), ...
        'captureSampleRateHz', sampleRateHz, 'captureDurationSec', 0.25, ...
        'hardwareCenterFrequencyHz', sourceCfg.fc, ...
        'decodeElapsedSec', decoded.decodeElapsedSec, ...
        'totalElapsedSec', decoded.decodeElapsedSec, ...
        'expectedOtaPacketCount', expectedPackets, ...
        'expectedProtocolFrameCount', expectedFrames, ...
        'packetSuccessRate', packetRate, 'frameSuccessRate', frameRate, ...
        'best', struct('validPacketCount', decoded.validPacketCount, ...
            'validFrameCount', decoded.validFrameCount, 'frames', []), ...
        'diagnosticUpdates', cachedUpdates, ...
        'infoCommandRatesHz', infoRates, ...
        'infoCommandTotalCounts', infoTotalCounts, ...
        'recordIndex', recordIndex);
end

function opt = local_normalize_options(opt)
    opt.Channel = upper(strtrim(string(opt.Channel)));
    opt.SourceName = lower(strtrim(string(opt.SourceName)));
    opt.RxRadioID = strtrim(string(opt.RxRadioID));
    opt.OutputPath = string(opt.OutputPath);
    opt.StopPath = string(opt.StopPath);
    if ~ismember(opt.Channel, ["A", "B"])
        error('Channel 仅支持 A 或 B。');
    end
    if ~any(opt.SourceName == FSK_RRC_ProjectConfig().sources.all)
        error('不支持的波源：%s。', opt.SourceName);
    end
    if isempty(regexp(opt.RxRadioID, '^ip:(?:\d{1,3}\.){3}\d{1,3}$', 'once'))
        error('RxRadioID 必须使用 ip:x.x.x.x 格式。');
    end
    if strlength(opt.OutputPath) == 0 || strlength(opt.StopPath) == 0
        error('OutputPath 和 StopPath 不能为空。');
    end
end

function snapshot = local_build_snapshot( ...
        opt, sourceCfg, result, cumulative, iteration, elapsedSec, useQuickSpectrum)
    if nargin < 7
        useQuickSpectrum = false;
    end
    raw = result.rawRxSamples(:);
    if isempty(raw)
        raw = result.rxSamples(:);
    end
    amplitude = abs(raw);
    rmsAmplitude = sqrt(mean(amplitude .^ 2));
    componentPeak = max([abs(real(raw)); abs(imag(raw))]);
    clipFraction = mean(abs(real(raw)) >= 0.98 | abs(imag(raw)) >= 0.98);

    if useQuickSpectrum
        [psdDb, fAxis] = local_quick_spectrum( ...
            raw, result.captureSampleRateHz, 2048);
    else
        [psdDb, fAxis] = local_welch_psd( ...
            raw, result.captureSampleRateHz, 2048);
    end
    psdRelative = psdDb - max(psdDb);
    spectrumIndexes = unique(round(linspace(1, numel(fAxis), min(720, numel(fAxis)))));
    spectrumMHz = (result.hardwareCenterFrequencyHz + fAxis(spectrumIndexes)) / 1e6;
    spectrumDb = psdRelative(spectrumIndexes);
    [~, peakIndex] = max(psdDb);
    peakOffsetHz = fAxis(peakIndex);

    inBand = abs(fAxis) <= sourceCfg.rfBandwidth / 2;
    guardStart = min(result.captureSampleRateHz * 0.45, sourceCfg.rxBandwidth * 0.65);
    guardBand = abs(fAxis) >= guardStart;
    linearPsd = 10 .^ (psdDb / 10);
    signalPower = sum(linearPsd(inBand));
    noiseBins = linearPsd(guardBand);
    if isempty(noiseBins)
        noiseFloor = median(linearPsd);
    else
        noiseFloor = median(noiseBins);
    end
    estimatedNoisePower = noiseFloor * max(nnz(inBand), 1);
    snrDb = 10 * log10(max(signalPower - estimatedNoisePower, eps) / ...
        max(estimatedNoisePower, eps));
    inBandFraction = signalPower / max(sum(linearPsd), eps);
    occupiedBandwidthHz = local_occupied_bandwidth(fAxis, linearPsd, 0.99);

    if isfield(result, 'diagnosticUpdates')
        frames = local_updates_for_json(result.diagnosticUpdates);
        cmdCounts = local_update_cmd_counts(result.diagnosticUpdates);
    else
        frames = local_frames_for_json(result.best.frames);
        cmdCounts = local_cmd_counts(result.best.frames);
    end
    actualGainDb = local_read_pluto_gain_cached(opt.RxRadioID, 1.0);

    metrics = struct( ...
        'captureDurationSec', result.captureDurationSec, ...
        'decodeElapsedSec', result.decodeElapsedSec, ...
        'totalElapsedSec', result.totalElapsedSec, ...
        'validPackets', result.best.validPacketCount, ...
        'expectedPackets', result.expectedOtaPacketCount, ...
        'packetSuccessRate', result.packetSuccessRate, ...
        'validPacketHz', result.best.validPacketCount / max(result.captureDurationSec, eps), ...
        'validFrames', result.best.validFrameCount, ...
        'expectedFrames', result.expectedProtocolFrameCount, ...
        'frameSuccessRate', result.frameSuccessRate, ...
        'validFrameHz', result.best.validFrameCount / max(result.captureDurationSec, eps), ...
        'averageValidFrameHz', cumulative.validFrames / max(elapsedSec, eps), ...
        'cumulativeValidFrames', cumulative.validFrames, ...
        'aggregatePacketSuccessRate', cumulative.validPackets / max(cumulative.expectedPackets, 1), ...
        'aggregateFrameSuccessRate', cumulative.validFrames / max(cumulative.expectedFrames, 1), ...
        'rmsDbfs', 20 * log10(max(rmsAmplitude, eps)), ...
        'componentPeak', componentPeak, ...
        'clipFraction', clipFraction, ...
        'actualGainDb', actualGainDb, ...
        'snrEstimateDb', snrDb, ...
        'inBandFraction', inBandFraction, ...
        'peakOffsetKHz', peakOffsetHz / 1e3, ...
        'occupiedBandwidthKHz', occupiedBandwidthHz / 1e3, ...
        'hardwareCenterMHz', result.hardwareCenterFrequencyHz / 1e6, ...
        'formalBandwidthKHz', sourceCfg.rfBandwidth / 1e3, ...
        'errorCount', cumulative.errors);

    snapshot = struct( ...
        'channel', opt.Channel, 'state', "running", ...
        'sourceName', opt.SourceName, 'sourceDisplayName', sourceCfg.displayName, ...
        'waveType', sourceCfg.waveType, 'radioID', opt.RxRadioID, ...
        'iteration', iteration, 'elapsedSec', elapsedSec, ...
        'updatedUnixSec', posixtime(datetime('now', 'TimeZone', 'UTC')), ...
        'metrics', metrics, ...
        'spectrumMHz', reshape(spectrumMHz, 1, []), ...
        'spectrumDb', reshape(spectrumDb, 1, []), ...
        'frames', frames, 'cmdCounts', cmdCounts);
    if isfield(result, 'infoCommandRatesHz')
        snapshot.infoCommandRatesHz = struct( ...
            'cmd0A01', result.infoCommandRatesHz(1), ...
            'cmd0A02', result.infoCommandRatesHz(2), ...
            'cmd0A03', result.infoCommandRatesHz(3), ...
            'cmd0A04', result.infoCommandRatesHz(4), ...
            'cmd0A05', result.infoCommandRatesHz(5));
        snapshot.infoCommandTotalCounts = struct( ...
            'cmd0A01', result.infoCommandTotalCounts(1), ...
            'cmd0A02', result.infoCommandTotalCounts(2), ...
            'cmd0A03', result.infoCommandTotalCounts(3), ...
            'cmd0A04', result.infoCommandTotalCounts(4), ...
            'cmd0A05', result.infoCommandTotalCounts(5));
    end
end

function [psdDb, fAxis] = local_welch_psd(raw, sampleRateHz, nfft)
    raw = raw(:);
    segmentLength = min(numel(raw), 131072);
    segment = raw(end-segmentLength+1:end);
    windowLength = min(4096, numel(segment));
    overlap = floor(windowLength / 2);
    [pxx, fAxis] = pwelch(segment, hann(windowLength), overlap, ...
        nfft, sampleRateHz, 'centered');
    psdDb = 10 * log10(max(real(pxx), eps));
end

function bandwidthHz = local_occupied_bandwidth(fAxis, powerValues, fraction)
    [sortedPower, order] = sort(powerValues, 'descend');
    cumulative = cumsum(sortedPower);
    keepCount = find(cumulative >= fraction * cumulative(end), 1);
    selected = fAxis(order(1:max(1, keepCount)));
    bandwidthHz = max(selected) - min(selected);
end

function framesOut = local_frames_for_json(frames)
    framesOut = struct('seq', {}, 'cmdId', {}, 'type', {}, 'summary', {}, 'fields', {});
    if isempty(frames)
        return;
    end
    startIndex = max(1, numel(frames) - 11);
    for k = startIndex:numel(frames)
        fr = frames(k).result;
        framesOut(end+1) = struct( ...
            'seq', double(fr.seq), ...
            'cmdId', sprintf('0x%04X', fr.cmdId), ...
            'type', string(fr.type), ...
            'summary', string(protocol_frame_to_text(fr)), ...
            'fields', local_decode_fields(fr.cmdId, fr.dataBytes)); %#ok<AGROW>
    end
end

function counts = local_cmd_counts(frames)
    ids = uint16(hex2dec({'0A01', '0A02', '0A03', '0A04', '0A05', '0A06'}));
    values = zeros(1, numel(ids));
    for k = 1:numel(frames)
        idx = find(ids == uint16(frames(k).result.cmdId), 1);
        if ~isempty(idx)
            values(idx) = values(idx) + 1;
        end
    end
    counts = struct('cmd0A01', values(1), 'cmd0A02', values(2), ...
        'cmd0A03', values(3), 'cmd0A04', values(4), ...
        'cmd0A05', values(5), 'cmd0A06', values(6));
end

function framesOut = local_updates_for_json(updates)
    framesOut = struct('seq', {}, 'cmdId', {}, 'type', {}, 'summary', {}, 'fields', {});
    startIndex = max(1, numel(updates) - 11);
    for k = startIndex:numel(updates)
        update = updates(k);
        framesOut(end+1) = struct( ...
            'seq', double(update.seq), ...
            'cmdId', sprintf('0x%04X', update.cmdId), ...
            'type', string(update.type), ...
            'summary', local_detail_summary(update.cmdId, update.dataBytes), ...
            'fields', local_decode_fields(update.cmdId, update.dataBytes)); %#ok<AGROW>
    end
end

function fields = local_decode_fields(cmdId, dataBytes)
    cmdId = uint16(cmdId);
    dataBytes = uint8(dataBytes(:));
    fields = struct();
    switch cmdId
        case uint16(hex2dec('0A01'))
            v = local_u16_array(dataBytes, 12);
            fields = struct('heroX', v(1), 'heroY', v(2), ...
                'engineerX', v(3), 'engineerY', v(4), ...
                'infantry3X', v(5), 'infantry3Y', v(6), ...
                'infantry4X', v(7), 'infantry4Y', v(8), ...
                'aerialX', v(9), 'aerialY', v(10), ...
                'sentryX', v(11), 'sentryY', v(12));
        case uint16(hex2dec('0A02'))
            v = local_u16_array(dataBytes, 6);
            fields = struct('heroHp', v(1), 'engineerHp', v(2), ...
                'infantry3Hp', v(3), 'infantry4Hp', v(4), ...
                'reservedHp', v(5), 'sentryHp', v(6));
        case uint16(hex2dec('0A03'))
            v = local_u16_array(dataBytes, 5);
            fields = struct('heroAmmo', v(1), 'infantry3Ammo', v(2), ...
                'infantry4Ammo', v(3), 'aerialAmmo', v(4), 'sentryAmmo', v(5));
        case uint16(hex2dec('0A04'))
            fields = struct('remainCoins', local_u16(dataBytes(1:2)), ...
                'totalCoins', local_u16(dataBytes(3:4)), ...
                'buffStatusBits', sprintf('0x%08X', local_u32(dataBytes(5:8))));
        case uint16(hex2dec('0A05'))
            names = {'hero', 'engineer', 'infantry3', 'infantry4', 'sentry'};
            offsets = [1 8 15 22 29];
            for k = 1:numel(names)
                o = offsets(k);
                fields.([names{k} 'Regen']) = double(dataBytes(o));
                fields.([names{k} 'Cooling']) = local_u16(dataBytes(o+1:o+2));
                fields.([names{k} 'Defense']) = double(dataBytes(o+3));
                fields.([names{k} 'NegDefense']) = double(dataBytes(o+4));
                fields.([names{k} 'Attack']) = local_u16(dataBytes(o+5:o+6));
            end
            fields.sentryPose = double(dataBytes(36));
            fields.heroMainStatus = double(dataBytes(37));
            fields.engineerMainStatus = double(dataBytes(38));
            fields.infantry3MainStatus = double(dataBytes(39));
            fields.infantry4MainStatus = double(dataBytes(40));
            fields.sentryMainStatus = double(dataBytes(41));
        case uint16(hex2dec('0A06'))
            fields = struct('jammerKey', string(char(dataBytes(:).')));
    end
end

function text = local_detail_summary(cmdId, dataBytes)
    fields = local_decode_fields(cmdId, dataBytes);
    switch uint16(cmdId)
        case uint16(hex2dec('0A01'))
            text = sprintf('坐标：英雄(%d,%d)，工程(%d,%d)，哨兵(%d,%d)', ...
                fields.heroX, fields.heroY, fields.engineerX, fields.engineerY, ...
                fields.sentryX, fields.sentryY);
        case uint16(hex2dec('0A02'))
            text = sprintf('血量：英雄=%d，工程=%d，3号=%d，4号=%d，哨兵=%d', ...
                fields.heroHp, fields.engineerHp, fields.infantry3Hp, ...
                fields.infantry4Hp, fields.sentryHp);
        case uint16(hex2dec('0A03'))
            text = sprintf('弹量：英雄=%d，3号=%d，4号=%d，空中=%d，哨兵=%d', ...
                fields.heroAmmo, fields.infantry3Ammo, fields.infantry4Ammo, ...
                fields.aerialAmmo, fields.sentryAmmo);
        case uint16(hex2dec('0A04'))
            text = sprintf('经济：剩余金币=%d，总金币=%d，增益点=%s', ...
                fields.remainCoins, fields.totalCoins, fields.buffStatusBits);
        case uint16(hex2dec('0A05'))
            text = sprintf('状态：英雄=%d，工程=%d，3号=%d，4号=%d，哨兵=%d，姿态=%d', ...
                fields.heroMainStatus, fields.engineerMainStatus, ...
                fields.infantry3MainStatus, fields.infantry4MainStatus, ...
                fields.sentryMainStatus, fields.sentryPose);
        case uint16(hex2dec('0A06'))
            text = "干扰波密钥：" + fields.jammerKey;
        otherwise
            text = sprintf('payload=%s', lower(reshape(dec2hex(dataBytes, 2).', 1, [])));
    end
end

function values = local_u16_array(bytes, count)
    values = zeros(1, count);
    for k = 1:count
        values(k) = local_u16(bytes(2*k-1:2*k));
    end
end

function value = local_u16(bytes)
    value = double(typecast(uint8(bytes(:)), 'uint16'));
end

function value = local_u32(bytes)
    value = double(typecast(uint8(bytes(:)), 'uint32'));
end

function counts = local_update_cmd_counts(updates)
    ids = uint16(hex2dec({'0A01', '0A02', '0A03', '0A04', '0A05', '0A06'}));
    values = zeros(1, numel(ids));
    for k = 1:numel(updates)
        idx = find(ids == uint16(updates(k).cmdId), 1);
        if ~isempty(idx)
            values(idx) = values(idx) + 1;
        end
    end
    counts = struct('cmd0A01', values(1), 'cmd0A02', values(2), ...
        'cmd0A03', values(3), 'cmd0A04', values(4), ...
        'cmd0A05', values(5), 'cmd0A06', values(6));
end

function gainDb = local_read_pluto_gain(radioID)
    command = sprintf( ...
        'iio_attr -u "%s" -i -c ad9361-phy voltage0 hardwaregain', ...
        char(radioID));
    [status, output] = system(command);
    match = regexp(output, '[-+]?\d+(?:\.\d+)?', 'match', 'once');
    if status == 0 && ~isempty(match)
        gainDb = str2double(match);
    else
        gainDb = NaN;
    end
end

function gainDb = local_read_pluto_gain_cached(radioID, minimumIntervalSec)
    % iio_attr 会启动外部进程，不能随每个 100 ms 解码结果调用。
    % 同一 worker 每秒最多读一次，其余快照复用最新硬件增益。
    persistent cachedRadioID cachedGainDb lastReadTic
    needsRead = isempty(lastReadTic) || isempty(cachedRadioID) || ...
        string(cachedRadioID) ~= string(radioID) || ...
        toc(lastReadTic) >= minimumIntervalSec;
    if needsRead
        cachedRadioID = string(radioID);
        cachedGainDb = local_read_pluto_gain(radioID);
        lastReadTic = tic;
    end
    gainDb = cachedGainDb;
end

function local_write_snapshot(outputPath, snapshot)
    outputPath = string(outputPath);
    tempPath = outputPath + sprintf('.tmp.%d', feature('getpid'));
    text = jsonencode(snapshot);
    fid = fopen(tempPath, 'w', 'n', 'UTF-8');
    if fid < 0
        error('无法写入 Web 快照临时文件：%s。', tempPath);
    end
    cleanupObj = onCleanup(@() fclose(fid));
    fwrite(fid, unicode2native(text, 'UTF-8'), 'uint8');
    clear cleanupObj;
    [ok, message] = movefile(tempPath, outputPath, 'f');
    if ~ok
        error('发布 Web 快照失败：%s。', message);
    end
end
