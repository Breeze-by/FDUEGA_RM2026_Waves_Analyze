function web_run_task(jobJsonPath, outDir)
%WEB_RUN_TASK MATLAB bridge used by the Python web debugger.
    if nargin < 2
        error('web_run_task requires jobJsonPath and outDir.');
    end

    bridgeDir = fileparts(mfilename('fullpath'));
    webDir = fileparts(bridgeDir);
    toolDir = fileparts(webDir);
    rootDir = fileparts(toolDir);
    addpath(rootDir);
    cd(rootDir);
    project_setup();

    if exist(outDir, 'dir') ~= 7
        mkdir(outDir);
    end

    diaryFile = fullfile(outDir, 'matlab_diary.txt');
    diary(diaryFile);
    diary on;
    cleanupObj = onCleanup(@() local_cleanup_diary());

    job = jsondecode(fileread(jobJsonPath));
    fprintf('[网页调试器] 任务=%s | 输出目录=%s\n', string(job.task), string(outDir));

    try
        switch string(job.task)
            case "sim"
                result = local_run_sim(job.params, outDir);
            case "tx"
                result = local_run_tx(job.params, outDir);
            case "rx"
                result = local_run_rx(job.params, outDir);
            case "auto_rx"
                result = local_run_auto_rx(job.params, outDir);
            otherwise
                error('Unknown web debugger task: %s', string(job.task));
        end

        result.ok = true;
        result.task = string(job.task);
        result.finishedAt = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
        local_write_json(fullfile(outDir, 'result.json'), result);
        fprintf('[网页调试器] 结果已写入：%s\n', fullfile(outDir, 'result.json'));
    catch ME
        err = struct();
        err.ok = false;
        err.task = string(job.task);
        err.message = string(ME.message);
        err.identifier = string(ME.identifier);
        err.report = string(getReport(ME, 'extended', 'hyperlinks', 'off'));
        err.finishedAt = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
        local_write_json(fullfile(outDir, 'result.json'), err);
        fprintf(2, '%s\n', err.report);
        rethrow(ME);
    end
end

function result = local_run_sim(params, outDir)
    ebN0Vec = local_parse_numeric_vector(local_get_string(params, 'EbN0dB_vec', "0:1:25"));
    args = { ...
        'SourceName', local_get_string(params, 'SourceName', "red_broadcast"), ...
        'EbN0dB_vec', ebN0Vec, ...
        'ShowPlots', false, ...
        'UseMultipath', local_get_bool(params, 'UseMultipath', false), ...
        'H_chan', local_parse_numeric_vector(local_get_string(params, 'H_chan', "[1 0 0.25*exp(1j*0.7)]")), ...
        'UseFlatFade', local_get_bool(params, 'UseFlatFade', false), ...
        'RepeatInBuffer', local_get_double(params, 'RepeatInBuffer', 40) ...
    };

    simResult = FSK_RRC_Sim(args{:});
    local_plot_sim(simResult, ebN0Vec, outDir);
    local_write_sim_csv(simResult, ebN0Vec, outDir);

    result = struct();
    result.summary = local_source_summary(simResult.cfg);
    finiteBer = simResult.totalBerVec(isfinite(simResult.totalBerVec));
    if isempty(finiteBer)
        minBer = NaN;
    else
        minBer = min(finiteBer);
    end
    result.metrics = struct( ...
        'maxFrameSuccessRate', max(simResult.frameSuccessRate), ...
        'maxPacketSuccessRate', max(simResult.packetSuccessRate), ...
        'minBer', minBer, ...
        'points', numel(simResult.validFrameCount));
    result.series = struct( ...
        'EbN0dB', ebN0Vec, ...
        'matchedFrameCount', simResult.matchedFrameCount, ...
        'validPacketCount', simResult.validPacketCount, ...
        'frameSuccessRate', simResult.frameSuccessRate, ...
        'packetSuccessRate', simResult.packetSuccessRate, ...
        'totalBer', simResult.totalBerVec);
    result.protocolFrames = local_protocol_frame_summary(simResult.txData.protocolFrames);
    result.artifacts = ["sim_metrics.csv", "sim_summary.png"];
end

function result = local_run_tx(params, outDir)
    enablePluto = local_get_bool(params, 'EnablePlutoTx', false);
    txTimeSec = local_get_double(params, 'TxTimeSec', 2.0);
    if enablePluto && ~isfinite(txTimeSec)
        error('Web 调试器中的 Pluto 发射必须设置有限 TxTimeSec，避免 MATLAB batch 永久占用。');
    end

    args = { ...
        'SourceName', local_get_string(params, 'SourceName', "red_l1_jammer"), ...
        'RadioID', local_get_string(params, 'RadioID', "ip:192.168.2.1"), ...
        'TxGain_dB', local_get_double(params, 'TxGain_dB', 0), ...
        'TxTimeSec', txTimeSec, ...
        'RepeatInBuffer', local_get_double(params, 'RepeatInBuffer', 40), ...
        'EnablePlutoTx', enablePluto, ...
        'ShowPlots', false ...
    };

    txState = FSK_RRC_Trans(args{:});
    txData = txState.txData;
    local_plot_tx(txData, outDir);
    local_write_tx_preview_csv(txData, outDir);

    result = struct();
    result.summary = local_source_summary(txData.cfg);
    result.tx = struct( ...
        'enablePlutoTx', enablePluto, ...
        'radioId', local_get_string(params, 'RadioID', "ip:192.168.2.1"), ...
        'txGainDb', local_get_double(params, 'TxGain_dB', 0), ...
        'txTimeSec', txTimeSec, ...
        'txReleased', logical(txState.txReleased), ...
        'sampleCount', numel(txData.s_tx), ...
        'bufferDurationSec', numel(txData.s_tx) / txData.cfg.Fs, ...
        'bitCount', numel(txData.bits));
    result.cycle = local_cycle_summary(txData.cycleSpec);
    result.protocolFrames = local_protocol_frame_summary(txData.protocolFrames);
    result.artifacts = ["tx_preview.csv", "tx_waveform.png", "tx_spectrum.png"];
end

function result = local_run_rx(params, outDir)
    rxResult = local_call_recv(params);
    local_plot_rx(rxResult, outDir);
    local_write_rx_frames_csv(rxResult, outDir);

    result = local_rx_result_summary(rxResult);
    result.artifacts = ["rx_frames.csv", "rx_iq.png", "rx_process.png", "rx_decode.png"];
end

function rxResult = local_call_recv(params)
    args = { ...
        'SourceName', local_get_string(params, 'SourceName', "red_l1_jammer"), ...
        'RxRadioID', local_get_string(params, 'RxRadioID', "ip:192.168.2.1"), ...
        'UseAGC', local_get_bool(params, 'UseAGC', true), ...
        'RxGain_dB', local_get_double(params, 'RxGain_dB', 20), ...
        'SamplesPerFrame', local_get_double(params, 'SamplesPerFrame', 50000), ...
        'WarmupFrames', local_get_double(params, 'WarmupFrames', 4), ...
        'CaptureTimeSec', local_get_double(params, 'CaptureTimeSec', 1.2), ...
        'BW_lpf', local_get_optional_double(params, 'BW_lpf'), ...
        'EnablePlutoRx', local_get_bool(params, 'EnablePlutoRx', true), ...
        'ShowPlots', false ...
    };

    rxResult = FSK_RRC_Recv(args{:});
end

function result = local_rx_result_summary(rxResult)
    result = struct();
    result.summary = struct( ...
        'sourceName', string(rxResult.sourceName), ...
        'referenceMode', string(rxResult.referenceMode), ...
        'captureDurationSec', rxResult.captureDurationSec, ...
        'rfBandwidthHz', rxResult.rfBandwidthHz, ...
        'bwLpfHz', rxResult.bwLpfHz);
    result.metrics = struct( ...
        'expectedOtaPacketCount', rxResult.expectedOtaPacketCount, ...
        'validOtaPacketCount', rxResult.best.validPacketCount, ...
        'packetSuccessRate', rxResult.packetSuccessRate, ...
        'packetLossCount', rxResult.packetLossCount, ...
        'expectedProtocolFrameCount', rxResult.expectedProtocolFrameCount, ...
        'validProtocolFrameCount', rxResult.best.validFrameCount, ...
        'frameSuccessRate', rxResult.frameSuccessRate, ...
        'frameLossCount', rxResult.frameLossCount, ...
        'bestPhase', rxResult.best.phase, ...
        'bestBitShift', rxResult.best.bitShift);
    result.frames = local_decoded_frame_summary(rxResult.best.frames);
end

function result = local_run_auto_rx(params, outDir)
    status = local_get_web_status(params);
    action = local_build_web_jammer_action(status, params);

    result = struct();
    result.summary = struct( ...
        'gameStarted', logical(status.gameStarted), ...
        'teamColor', string(status.teamColor), ...
        'jammerLevel', status.jammerLevel, ...
        'sourceName', string(action.sourceName), ...
        'actionReason', string(action.reason));

    if ~action.shouldRun
        fprintf("[自动解析] 跳过：%s\n", action.reason);
        result.auto = struct( ...
            'success', false, ...
            'skipped', true, ...
            'attemptCount', 0, ...
            'key', "", ...
            'sourceName', string(action.sourceName), ...
            'reason', string(action.reason));
        result.metrics = struct('attemptCount', 0, 'success', false);
        result.frames = local_decoded_frame_summary([]);
        result.artifacts = strings(0, 1);
        return;
    end

    maxAttempts = local_get_double(params, 'MaxAttempts', 0);
    captureTimeSec = local_get_double(params, 'CaptureTimeSec', 3.0);
    if captureTimeSec <= 0
        captureTimeSec = 3.0;
    end

    attempt = 0;
    success = false;
    keyText = "";
    lastRxResult = [];
    keyFrame = struct();

    fprintf("[自动解析] 比赛已开始，目标波源=%s，单次采集 %.3f s。\n", action.sourceName, captureTimeSec);
    while maxAttempts <= 0 || attempt < maxAttempts
        attempt = attempt + 1;
        fprintf("\n[自动解析] 第 %d 次接收开始。\n", attempt);

        recvParams = params;
        recvParams.SourceName = action.sourceName;
        recvParams.CaptureTimeSec = captureTimeSec;
        recvParams.ShowPlots = false;
        lastRxResult = local_call_recv(recvParams);
        [keyText, keyFrame] = local_extract_jammer_key_from_result(lastRxResult);

        if strlength(keyText) > 0
            success = true;
            fprintf("[自动解析] 第 %d 次接收成功，干扰密钥=%s。\n", attempt, keyText);
            break;
        end

        fprintf("[自动解析] 第 %d 次未解析到有效干扰密钥，有效 OTA=%d，有效协议帧=%d。\n", ...
            attempt, lastRxResult.best.validPacketCount, lastRxResult.best.validFrameCount);
    end

    if isempty(lastRxResult)
        error("自动解析未执行任何接收。");
    end

    local_plot_rx(lastRxResult, outDir);
    local_write_rx_frames_csv(lastRxResult, outDir);

    result.summary.sourceName = string(action.sourceName);
    result.summary.captureDurationSec = lastRxResult.captureDurationSec;
    result.summary.rfBandwidthHz = lastRxResult.rfBandwidthHz;
    result.summary.bwLpfHz = lastRxResult.bwLpfHz;
    result.auto = struct( ...
        'success', logical(success), ...
        'skipped', false, ...
        'attemptCount', attempt, ...
        'key', string(keyText), ...
        'sourceName', string(action.sourceName), ...
        'reason', string(action.reason));
    if isfield(keyFrame, 'result') && isfield(keyFrame.result, 'seq')
        result.auto.seq = double(keyFrame.result.seq);
    else
        result.auto.seq = [];
    end
    result.metrics = struct( ...
        'attemptCount', attempt, ...
        'success', logical(success), ...
        'validOtaPacketCount', lastRxResult.best.validPacketCount, ...
        'validProtocolFrameCount', lastRxResult.best.validFrameCount, ...
        'packetSuccessRate', lastRxResult.packetSuccessRate, ...
        'frameSuccessRate', lastRxResult.frameSuccessRate, ...
        'bestPhase', lastRxResult.best.phase, ...
        'bestBitShift', lastRxResult.best.bitShift);
    result.frames = local_decoded_frame_summary(lastRxResult.best.frames);
    result.artifacts = ["rx_frames.csv", "rx_iq.png", "rx_process.png", "rx_decode.png"];
end

function status = local_get_web_status(params)
    status = struct();
    status.gameStarted = local_get_bool(params, 'GameStarted', false);
    status.teamColor = local_parse_color(local_get_string(params, 'TeamColor', ""));
    status.jammerLevel = round(local_get_double(params, 'JammerLevel', 0));
end

function action = local_build_web_jammer_action(status, ~)
    action = struct('shouldRun', false, 'reason', "", 'sourceName', "");

    if ~status.gameStarted
        action.reason = "比赛未开始";
        return;
    end

    if strlength(status.teamColor) == 0
        action.reason = "队伍颜色未知";
        return;
    end

    if ~ismember(status.jammerLevel, [1 2 3])
        action.reason = "当前无需要解析的干扰波等级";
        return;
    end

    sourceName = sprintf("%s_l%d_jammer", status.teamColor, status.jammerLevel);
    try
        get_gfsk_source_config(sourceName);
    catch ME
        action.reason = string(ME.message);
        return;
    end

    action.shouldRun = true;
    action.reason = "需要解析";
    action.sourceName = string(sourceName);
end

function [keyText, frameItem] = local_extract_jammer_key_from_result(rxResult)
    keyText = "";
    frameItem = struct();

    if ~isfield(rxResult, 'best') || ~isfield(rxResult.best, 'frames') || isempty(rxResult.best.frames)
        return;
    end

    frames = rxResult.best.frames;
    for k = 1:numel(frames)
        fr = frames(k).result;
        if ~isfield(fr, 'ok') || ~fr.ok
            continue;
        end
        if ~isfield(fr, 'cmdId') || fr.cmdId ~= uint16(hex2dec('0A06'))
            continue;
        end
        if ~isfield(fr, 'payload') || ~isfield(fr.payload, 'jammerKey')
            continue;
        end
        if isfield(fr.payload, 'isValidAlphaNum') && ~fr.payload.isValidAlphaNum
            continue;
        end

        keyText = string(fr.payload.jammerKey);
        frameItem = frames(k);
        return;
    end
end

function color = local_parse_color(value)
    txt = lower(strtrim(string(value)));
    if any(txt == ["red", "r", "红", "红方"])
        color = "red";
    elseif any(txt == ["blue", "b", "蓝", "蓝方"])
        color = "blue";
    else
        color = "";
    end
end

function local_plot_sim(simResult, ebN0Vec, outDir)
    f = figure('Visible', 'off', 'Name', 'Web Sim Summary');
    tiledlayout(2, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
    eb = ebN0Vec(:);
    nexttile; plot(eb, simResult.frameSuccessRate, '-o'); grid on; title('协议帧成功率'); xlabel('Eb/N0 (dB)');
    nexttile; plot(eb, simResult.packetSuccessRate, '-o'); grid on; title('OTA 包成功率'); xlabel('Eb/N0 (dB)');
    nexttile; plot(eb, simResult.matchedFrameCount, '-o'); grid on; title('匹配协议帧数量'); xlabel('Eb/N0 (dB)');
    nexttile; plot(eb, simResult.totalBerVec, '-o'); grid on; title('BER'); xlabel('Eb/N0 (dB)');
    local_save_figure(f, fullfile(outDir, 'sim_summary.png'));
end

function local_plot_tx(txData, outDir)
    cfg = txData.cfg;
    nWave = min(20 * cfg.sps, numel(txData.bitWave));
    tMs = (0:nWave-1).' / cfg.Fs * 1e3;
    instFreqHz = txData.phaseStep * cfg.Fs / (2*pi);

    f = figure('Visible', 'off', 'Name', '发射波形');
    tiledlayout(2, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
    nexttile; stairs(tMs, txData.bitWave(1:nWave)); hold on; plot(tMs, txData.shapedControl(1:nWave)); hold off; grid on; title('NRZ 与 Gaussian 成形'); xlabel('ms');
    nexttile; plot(tMs, instFreqHz(1:nWave) / 1e3); grid on; title('瞬时频偏'); xlabel('ms'); ylabel('kHz');
    nexttile; plot(real(txData.s_tx(1:min(3000, end)))); hold on; plot(imag(txData.s_tx(1:min(3000, end)))); hold off; grid on; title('发射 IQ 时域');
    nexttile; stairs(txData.bits(1:min(240, end))); ylim([-0.2 1.2]); grid on; title('首段 OTA 比特');
    local_save_figure(f, fullfile(outDir, 'tx_waveform.png'));

    f = figure('Visible', 'off', 'Name', '发射频谱与星座');
    tiledlayout(1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
    nexttile; plot(real(txData.s_tx(1:min(5000, end))), imag(txData.s_tx(1:min(5000, end))), '.'); axis equal; grid on; title('发射 IQ 星座');
    nexttile; [fx, psd] = simple_spectrum_db(txData.s_tx, cfg.Fs, 8192); plot(fx/1e3, psd); grid on; title('发射频谱'); xlabel('kHz');
    local_save_figure(f, fullfile(outDir, 'tx_spectrum.png'));
end

function local_plot_rx(rxResult, outDir)
    r = rxResult.rxSamples;
    Fs = rxResult.params.Fs;
    nWave = min(round(0.01 * Fs), numel(r));
    tMs = (0:nWave-1).' / Fs * 1e3;

    f = figure('Visible', 'off', 'Name', '接收 IQ');
    tiledlayout(2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');
    nexttile; plot(tMs, real(r(1:nWave))); hold on; plot(tMs, imag(r(1:nWave))); hold off; grid on; title('接收 IQ 时域'); xlabel('ms');
    nexttile; plot(real(r(1:min(5000, end))), imag(r(1:min(5000, end))), '.'); axis equal; grid on; title('接收 IQ 星座');
    local_save_figure(f, fullfile(outDir, 'rx_iq.png'));

    f = figure('Visible', 'off', 'Name', '接收处理过程');
    tiledlayout(2, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
    nexttile; [fx, psd] = simple_spectrum_db(r, Fs, 8192); plot(fx/1e3, psd); grid on; title('接收频谱'); xlabel('kHz');
    nexttile; plot(rxResult.m_hat(1:min(5000, end))); grid on; title('鉴频输出');
    nexttile; plot(rxResult.bitMetricStream(1:min(5000, end))); grid on; title('比特判决统计量');
    nexttile; stairs(rxResult.best.bitsHat(1:min(240, end))); ylim([-0.2 1.2]); grid on; title('恢复比特流');
    local_save_figure(f, fullfile(outDir, 'rx_process.png'));

    f = figure('Visible', 'off', 'Name', '接收解码结果');
    tiledlayout(1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
    nexttile;
    if ~isempty(rxResult.best.otaPackets)
        starts = [rxResult.best.otaPackets.startIndex];
        stem(starts, ones(size(starts)), 'filled'); grid on; title('有效 OTA 包位置'); xlabel('字节流起始位置');
    else
        text(0.1, 0.5, '未找到有效 OTA 包'); axis off;
    end
    nexttile;
    if ~isempty(rxResult.best.frames)
        cmdIds = arrayfun(@(x) double(x.result.cmdId), rxResult.best.frames);
        stem(cmdIds, 'filled'); grid on; title('有效协议帧 cmdId');
    else
        text(0.1, 0.5, '未找到有效协议帧'); axis off;
    end
    local_save_figure(f, fullfile(outDir, 'rx_decode.png'));
end

function local_write_sim_csv(simResult, ebN0Vec, outDir)
    T = table(ebN0Vec(:), simResult.matchedFrameCount(:), ...
        simResult.validPacketCount(:), simResult.frameSuccessRate(:), ...
        simResult.packetSuccessRate(:), simResult.totalBerVec(:), ...
        'VariableNames', {'EbN0dB', 'MatchedFrameCount', 'ValidPacketCount', ...
        'FrameSuccessRate', 'PacketSuccessRate', 'TotalBer'});
    writetable(T, fullfile(outDir, 'sim_metrics.csv'));
end

function local_write_tx_preview_csv(txData, outDir)
    n = min(5000, numel(txData.s_tx));
    idx = (1:n).';
    T = table(idx, real(txData.s_tx(1:n)), imag(txData.s_tx(1:n)), ...
        'VariableNames', {'Index', 'I', 'Q'});
    writetable(T, fullfile(outDir, 'tx_preview.csv'));
end

function local_write_rx_frames_csv(rxResult, outDir)
    frames = local_decoded_frame_summary(rxResult.best.frames);
    if isempty(frames)
        T = table([], [], strings(0, 1), strings(0, 1), ...
            'VariableNames', {'Seq', 'CmdId', 'Type', 'Text'});
    else
        seq = [frames.seq].';
        cmdId = [frames.cmdId].';
        typeName = string({frames.type}).';
        text = string({frames.text}).';
        T = table(seq, cmdId, typeName, text, 'VariableNames', {'Seq', 'CmdId', 'Type', 'Text'});
    end
    writetable(T, fullfile(outDir, 'rx_frames.csv'));
end

function summary = local_source_summary(cfg)
    summary = struct( ...
        'sourceName', string(cfg.name), ...
        'displayName', string(cfg.displayName), ...
        'waveType', string(cfg.waveType), ...
        'centerFrequencyHz', cfg.fc, ...
        'rfBandwidthHz', cfg.rfBandwidth, ...
        'powerDbm', cfg.power_dBm, ...
        'sampleRateHz', cfg.Fs, ...
        'symbolRateHz', cfg.Rs, ...
        'sps', cfg.sps, ...
        'bt', cfg.bt, ...
        'deltaFHz', cfg.deltaF, ...
        'sensitivity', cfg.sensitivity);
end

function summary = local_cycle_summary(cycleSpec)
    summary = struct( ...
        'protocolFrameCountPerCycle', cycleSpec.protocolFrameCountPerCycle, ...
        'otaPacketCountPerCycle', cycleSpec.otaPacketCountPerCycle, ...
        'payloadBytesPerCycle', cycleSpec.payloadBytesPerCycle, ...
        'cycleDurationSec', cycleSpec.cycleDurationSec);
end

function frames = local_protocol_frame_summary(protocolFrames)
    frames = repmat(struct('index', 0, 'seq', 0, 'cmdId', 0, 'bytes', 0, 'summary', ""), 0, 1);
    for k = 1:numel(protocolFrames)
        frames(k, 1).index = k;
        frames(k, 1).seq = double(protocolFrames(k).seq);
        frames(k, 1).cmdId = double(protocolFrames(k).cmdId);
        frames(k, 1).bytes = numel(protocolFrames(k).frameBytes);
        frames(k, 1).summary = string(protocolFrames(k).summary);
    end
end

function frames = local_decoded_frame_summary(bestFrames)
    frames = repmat(struct('index', 0, 'seq', 0, 'cmdId', 0, 'type', "", 'text', ""), 0, 1);
    for k = 1:numel(bestFrames)
        fr = bestFrames(k).result;
        frames(k, 1).index = k;
        frames(k, 1).seq = double(fr.seq);
        frames(k, 1).cmdId = double(fr.cmdId);
        frames(k, 1).type = string(fr.type);
        frames(k, 1).text = string(protocol_frame_to_text(fr));
    end
end

function local_save_figure(fig, path)
    try
        exportgraphics(fig, path, 'Resolution', 140);
    catch
        saveas(fig, path);
    end
    close(fig);
end

function value = local_get_string(s, fieldName, defaultValue)
    if isfield(s, fieldName) && ~isempty(s.(fieldName))
        value = string(s.(fieldName));
    else
        value = string(defaultValue);
    end
end

function value = local_get_double(s, fieldName, defaultValue)
    if isfield(s, fieldName) && ~isempty(s.(fieldName))
        raw = s.(fieldName);
        if isnumeric(raw) || islogical(raw)
            value = double(raw);
        else
            value = str2double(string(raw));
            if isnan(value)
                error("参数 %s 不是有效数字：%s", fieldName, string(raw));
            end
        end
    else
        value = double(defaultValue);
    end
end

function value = local_get_optional_double(s, fieldName)
    if isfield(s, fieldName) && ~isempty(s.(fieldName)) && strlength(string(s.(fieldName))) > 0
        raw = s.(fieldName);
        if isnumeric(raw) || islogical(raw)
            value = double(raw);
        else
            value = str2double(string(raw));
            if isnan(value)
                error("参数 %s 不是有效数字：%s", fieldName, string(raw));
            end
        end
    else
        value = [];
    end
end

function value = local_get_bool(s, fieldName, defaultValue)
    if isfield(s, fieldName) && ~isempty(s.(fieldName))
        raw = s.(fieldName);
        if islogical(raw)
            value = logical(raw);
        elseif isnumeric(raw)
            value = raw ~= 0;
        else
            value = any(strcmpi(string(raw), ["true", "1", "yes", "on"]));
        end
    else
        value = logical(defaultValue);
    end
end

function vec = local_parse_numeric_vector(textValue)
    textValue = strtrim(string(textValue));
    if strlength(textValue) == 0
        vec = [];
        return;
    end
    expr = char(textValue);
    if ~(startsWith(textValue, "[") && endsWith(textValue, "]")) && contains(textValue, " ")
        expr = char("[" + textValue + "]");
    end
    vec = eval(expr); %#ok<EVLDIR> Web debugger is local-only and exposes this as an advanced MATLAB expression field.
end

function local_write_json(path, data)
    text = jsonencode(data, 'PrettyPrint', true);
    fid = fopen(path, 'w', 'n', 'UTF-8');
    if fid < 0
        error('Cannot write JSON file: %s', path);
    end
    cleaner = onCleanup(@() fclose(fid));
    fprintf(fid, '%s', char(text));
end

function local_cleanup_diary()
    try
        diary off;
    catch
    end
end
