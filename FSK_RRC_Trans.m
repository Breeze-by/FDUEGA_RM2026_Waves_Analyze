function txState = FSK_RRC_Trans(varargin)
    project_setup();
    close all;
    cleanup_pluto_workspace_objects();
    cfgDefault = FSK_RRC_ProjectConfig();
    txCfg = cfgDefault.tx;

    p = inputParser;
    addParameter(p, 'SourceName', txCfg.SourceName);
    addParameter(p, 'RadioID', txCfg.RadioID);
    addParameter(p, 'TxGain_dB', txCfg.TxGain_dB);
    addParameter(p, 'TxTimeSec', txCfg.TxTimeSec);
    addParameter(p, 'RepeatInBuffer', txCfg.RepeatInBuffer);
    addParameter(p, 'JammerKey', "");
    addParameter(p, 'EnablePlutoTx', txCfg.EnablePlutoTx);
    addParameter(p, 'ShowPlots', txCfg.ShowPlots);
    parse(p, varargin{:});
    opt = p.Results;

    rng(0);
    txData = build_gfsk_tx_waveform(opt.SourceName, opt.RepeatInBuffer, opt.JammerKey);
    cfg = txData.cfg;
    cycleSpec = txData.cycleSpec;
    instFreqHz = txData.phaseStep * cfg.Fs / (2*pi);

    fprintf("\n=== 发射配置 ===\n");
    fprintf("当前源类型：%s\n", cfg.displayName);
    fprintf("波形类别：%s\n", local_wave_type_text(cfg.waveType));
    fprintf("中心频点：%.3f MHz\n", cfg.fc/1e6);
    fprintf("射频带宽：%.3f MHz\n", cfg.rfBandwidth/1e6);
    fprintf("额定功率：%g dBm\n", cfg.power_dBm);
    fprintf("采样率：%.3f MHz | 每符号采样点：%d | BT=%.2f\n", ...
        cfg.Fs/1e6, cfg.sps, cfg.bt);
    fprintf("符号率/比特率：%.3f kHz | 频偏：%.3f kHz | 灵敏度：%.4f rad/sample\n", ...
        cfg.Rs/1e3, cfg.deltaF/1e3, cfg.sensitivity);

    fprintf("\n=== 周期信息 ===\n");
    fprintf("每周期协议帧数：%d\n", cycleSpec.protocolFrameCountPerCycle);
    fprintf("每周期平均 OTA 包数：%.3f\n", cycleSpec.otaPacketCountPerCycle);
    fprintf("每周期有效字节：%d\n", cycleSpec.payloadBytesPerCycle);
    fprintf("数据推送速率：%d byte/s\n", cfg.dataPushRateBytesPerSec);
    fprintf("单周期时长：%.3f ms\n", cycleSpec.cycleDurationSec*1e3);
    fprintf("缓存 OTA 包数：%d | 缓存尾部补齐：%d 字节 | 空闲样本：%d\n", ...
        txData.otaPacketCountInBuffer, txData.bufferOtaSpec.paddingLengthBytes, txData.idleSampleCount);
    fprintf("发射缓存比特数：%d\n", numel(txData.bits));
    fprintf("发射样本数：%d\n", numel(txData.s_tx));
    fprintf("当前缓存波形时长：%.3f s\n", numel(txData.s_tx)/cfg.Fs);
    fprintf("单比特时长：%.3f us\n", 1e6/cfg.Rs);

    fprintf("\n=== 周期内协议帧 ===\n");
    for k = 1:numel(txData.protocolFrames)
        frameInfo = txData.protocolFrames(k);
        fprintf("帧 %d | 命令码=0x%04X | 序号=%d | 帧长=%d 字节\n", ...
            k, frameInfo.cmdId, frameInfo.seq, numel(frameInfo.frameBytes));
        fprintf("      内容：%s\n", frameInfo.summary);
    end

    if opt.ShowPlots
        local_show_tx_plots(txData, instFreqHz);
    end

    txState = struct('txData', txData, 'txReleased', true);
    if ~opt.EnablePlutoTx
        fprintf("已关闭 Pluto 发射，仅完成波形生成。\n");
        return;
    end

    radioCtx = resolve_pluto_radio_id(opt.RadioID, "tx");
    resolvedRadioID = radioCtx.resolvedRadioID;
    if radioCtx.usedDefaultRoute
        fprintf("使用默认 Pluto 发射地址：%s\n", resolvedRadioID);
    end

    tx = sdrtx('Pluto', ...
        'RadioID', char(resolvedRadioID), ...
        'CenterFrequency', cfg.fc, ...
        'BasebandSampleRate', cfg.Fs, ...
        'Gain', opt.TxGain_dB);
    cleanupTx = onCleanup(@() local_release_tx(tx));
    local_try_set_rf_bandwidth(tx, cfg.rfBandwidth);

    txInfo = info(tx);
    disp(txInfo);
    fprintf("\n=== 开始发射 ===\n");
    fprintf("发射设备地址：%s\n", resolvedRadioID);
    fprintf("中心频点：%.3f MHz\n", cfg.fc/1e6);
    fprintf("基带采样率：%.3f MHz\n", cfg.Fs/1e6);
    fprintf("发射增益：%.2f dB\n", opt.TxGain_dB);
    fprintf("射频带宽：%.3f MHz\n", cfg.rfBandwidth/1e6);

    transmitRepeat(tx, txData.s_tx);
    txActiveEpochSec = posixtime(datetime('now', 'TimeZone', 'UTC'));
    fprintf('TX_ACTIVE_EPOCH=%.6f\n', txActiveEpochSec);
    txState.txReleased = false;

    if isfinite(opt.TxTimeSec)
        pause(opt.TxTimeSec);
        release(tx);
        clear tx;
        txState.txReleased = true;
        fprintf("定时发射完成，设备已释放。\n");
    else
        fprintf("Pluto 正在循环发射。如需停止，可在当前工作区执行 release(tx)。\n");
        assignin('base', 'tx', tx);
        pause(inf);
    end
end

function local_release_tx(tx)
    if isempty(tx)
        return;
    end

    try
        release(tx);
    catch
    end
end

function textOut = local_wave_type_text(waveType)
    switch string(waveType)
        case "broadcast"
            textOut = "信息波";
        case "jammer"
            textOut = "干扰波";
        otherwise
            textOut = char(string(waveType));
    end
end

function local_show_tx_plots(txData, instFreqHz)
    cfg = txData.cfg;
    tMs = (0:numel(txData.phaseStep)-1).' / cfg.Fs * 1e3;
    Nfft = 8192;
    H = fftshift(fft(txData.h_gauss, Nfft));
    fAxis = (-Nfft/2:Nfft/2-1).' / Nfft * cfg.Fs;
    Hdb = 20*log10(abs(H)/max(abs(H)+eps) + 1e-12);

    nShowWave = min(numel(txData.bitWave), 20*cfg.sps);
    tShowMs = (0:nShowWave-1).' / cfg.Fs * 1e3;
    packetBytes = txData.cycleSpec.otaSpec.packets(1).packetBytes;
    nShowBits = min(192, numel(txData.bits));

    figure('Name', '发射端 Gaussian 细节');
    subplot(2,2,1);
    stem(txData.h_gauss, 'filled'); grid on;
    xlabel('抽头序号'); ylabel('幅度');
    title(sprintf('Gaussian 抽头 | BT=%.2f, span=%d, sps=%d', cfg.bt, cfg.gaussianSpan, cfg.sps));

    subplot(2,2,2);
    plot(fAxis/1e3, Hdb, 'LineWidth', 1.1); grid on;
    xlabel('频率 (kHz)'); ylabel('幅度 (dB, 归一化)');
    title('Gaussian 滤波器频响');

    subplot(2,2,3);
    stairs(tShowMs, txData.bitWave(1:nShowWave), 'LineWidth', 1.0); hold on;
    plot(tShowMs, txData.shapedControl(1:nShowWave), 'LineWidth', 1.2);
    hold off; grid on;
    xlabel('时间 (ms)'); ylabel('电平');
    legend('NRZ 比特波形', 'Gaussian 成形后控制量', 'Location', 'best');
    title('调频控制信号');

    subplot(2,2,4);
    plot(tShowMs, instFreqHz(1:nShowWave)/1e3, 'LineWidth', 1.2); grid on;
    xlabel('时间 (ms)'); ylabel('kHz');
    title('瞬时频偏');

    figure('Name', '发射概览');
    subplot(3,2,1);
    stairs(txData.bits(1:nShowBits), 'LineWidth', 1.0); grid on;
    xlabel('比特索引'); ylabel('比特值');
    ylim([-0.2 1.2]);
    title('首段 OTA 比特流');

    subplot(3,2,2);
    stem(double(packetBytes), 'filled'); grid on;
    xlabel('字节索引'); ylabel('数值');
    title('首个 OTA 包字节');

    subplot(3,2,3);
    plot(tMs(1:min(1200,end)), txData.phi(1:min(1200,end)), 'LineWidth', 1.1); grid on;
    xlabel('时间 (ms)'); ylabel('弧度');
    title('连续相位');

    subplot(3,2,4);
    plot(real(txData.s_tx(1:min(1200,end))), 'LineWidth', 1.0); hold on;
    plot(imag(txData.s_tx(1:min(1200,end))), 'LineWidth', 1.0);
    hold off; grid on;
    xlabel('采样点'); ylabel('幅度');
    legend('I', 'Q', 'Location', 'best');
    title('发射 IQ 波形');

    subplot(3,2,5);
    plot(real(txData.s_tx(1:min(4000,end))), imag(txData.s_tx(1:min(4000,end))), '.');
    axis equal; grid on;
    xlabel('I'); ylabel('Q');
    title('发射 IQ 星座');

    subplot(3,2,6);
    [fAxisTx, psdTx] = simple_spectrum_db(txData.s_tx, cfg.Fs, 8192);
    plot(fAxisTx/1e3, psdTx, 'LineWidth', 1.1); grid on;
    xlabel('频率 (kHz)'); ylabel('幅度 (dB, 归一化)');
    title('发射频谱');
end

function local_try_set_rf_bandwidth(obj, rfBandwidth)
    try
        if isprop(obj, 'RFBandwidth')
            obj.RFBandwidth = rfBandwidth;
        end
    catch
    end
end
