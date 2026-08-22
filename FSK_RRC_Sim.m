function simResult = FSK_RRC_Sim(varargin)
    close all; clc;
    project_setup();
    rng(0);

    cfgDefault = FSK_RRC_ProjectConfig();
    simCfg = cfgDefault.sim;

    p = inputParser;
    addParameter(p, 'SourceName', simCfg.SourceName);
    addParameter(p, 'EbN0dB_vec', simCfg.EbN0dB_vec);
    addParameter(p, 'ShowPlots', simCfg.ShowPlots);
    addParameter(p, 'UseMultipath', simCfg.UseMultipath);
    addParameter(p, 'H_chan', simCfg.H_chan);
    addParameter(p, 'UseFlatFade', simCfg.UseFlatFade);
    addParameter(p, 'RepeatInBuffer', simCfg.RepeatInBuffer);
    parse(p, varargin{:});
    opt = p.Results;

    sourceName = string(opt.SourceName);
    EbN0dB_vec = opt.EbN0dB_vec;
    showPlots = opt.ShowPlots;
    useMultipath = opt.UseMultipath;
    h_chan = opt.H_chan;
    useFlatFade = opt.UseFlatFade;

    txData = build_gfsk_tx_waveform(sourceName, opt.RepeatInBuffer);
    cfg = txData.cfg;
    cfgRule = txData.cfgRule;
    cycleSpec = txData.cycleSpec;
    Fs = cfg.Fs;
    Rs = cfg.Rs;
    sps = cfg.sps;
    Rb = Rs;
    instFreqHz = txData.phaseStep * Fs / (2*pi);

    fprintf("当前源：%s | 类型=%s | 中心频点=%.3f MHz | RF 带宽=%.3f MHz | 功率=%g dBm\n", ...
        cfg.displayName, cfg.waveType, cfg.fc/1e6, cfg.rfBandwidth/1e6, cfg.power_dBm);
    fprintf("规则检查：Fs/Rs=%.6f | sps=%d | BT=%.2f | sensitivity=%.4f rad/sample | allOk=%d\n", ...
        cfgRule.expectedSps, cfg.sps, cfg.bt, cfg.sensitivity, cfgRule.allOk);
    fprintf("周期内协议帧=%d | 平均 OTA 包=%.3f | 单周期有效字节=%d | 单周期时长=%.3f ms\n", ...
        cycleSpec.protocolFrameCountPerCycle, cycleSpec.otaPacketCountPerCycle, ...
        cycleSpec.payloadBytesPerCycle, cycleSpec.cycleDurationSec*1e3);

    for k = 1:numel(txData.protocolFrames)
        frameInfo = txData.protocolFrames(k);
        fprintf("  [%d] cmdId=0x%04X | seq=%d | bytes=%d | %s\n", ...
            k, frameInfo.cmdId, frameInfo.seq, numel(frameInfo.frameBytes), frameInfo.summary);
    end

    if showPlots
        local_show_tx_plots(txData, instFreqHz);
    end

    validFrameCount = zeros(size(EbN0dB_vec));
    matchedFrameCount = zeros(size(EbN0dB_vec));
    validPacketCount = zeros(size(EbN0dB_vec));
    frameSuccessRate = zeros(size(EbN0dB_vec));
    packetSuccessRate = zeros(size(EbN0dB_vec));
    bestBitShiftVec = zeros(size(EbN0dB_vec));
    totalBerVec = nan(size(EbN0dB_vec));

    midIdx = ceil(numel(EbN0dB_vec)/2);
    channelFilterOrder = 240;
    channelCutoffHz = cfg.rfBandwidth / 2;
    channelTaps = fir1(channelFilterOrder, channelCutoffHz / (Fs / 2), ...
        hamming(channelFilterOrder + 1));
    quadratureDemodGain = 1.5;
    expectedProtocolFrameCount = txData.protocolFrameCountInBuffer;
    expectedOtaPacketCount = txData.otaPacketCountInBuffer;

    fprintf("\n=== 接收设置：通道低通→正交鉴频→过零符号同步 ===\n");

    for ii = 1:numel(EbN0dB_vec)
        EbN0dB = EbN0dB_vec(ii);
        r = txData.s_bb;

        if useMultipath
            r = filter(h_chan(:), 1, r);
        end

        if useFlatFade
            g = (randn + 1j*randn)/sqrt(2);
            r = g * r;
        end

        Ps = mean(abs(r).^2);
        EbN0 = 10^(EbN0dB/10);
        N0 = (Ps / Rb) / EbN0;
        sig2 = N0 * Fs;
        w = sqrt(sig2/2) * (randn(size(r)) + 1j*randn(size(r)));
        r = r + w;

        r = filter(channelTaps, 1, r);
        m_hat = fsk_discriminator_hz(r, Fs) * ...
            (2*pi / Fs) * quadratureDemodGain;
        if cfg.waveType == "jammer"
            hGaussian = make_gaussian_taps(cfg.bt, cfg.gaussianSpan, sps);
            m_hat = filter(hGaussian, 1, m_hat);
        end
        syncScale = sqrt(mean(abs(m_hat).^2));
        if ~isfinite(syncScale) || syncScale <= eps
            syncScale = 1;
        end
        symbolSync = comm.SymbolSynchronizer( ...
            'Modulation', 'PAM/PSK/QAM', ...
            'TimingErrorDetector', 'Zero-Crossing (decision-directed)', ...
            'SamplesPerSymbol', sps, ...
            'DampingFactor', 1.0, ...
            'NormalizedLoopBandwidth', 0.005, ...
            'DetectorGain', 1.0);
        bitMetricStream = symbolSync(real(m_hat) / syncScale);
        release(symbolSync);
        simDecodeRef = txData.rxReference;
        simDecodeRef.protocolFrames = txData.protocolFrames;
        simDecodeRef.useExpectedPayloadMatching = true;
        best = decode_gfsk_symbol_stream(bitMetricStream, simDecodeRef);

        validFrameCount(ii) = numel(best.frames);
        matchedFrameCount(ii) = best.matchedFrameCount;
        validPacketCount(ii) = best.validPacketCount;
        frameSuccessRate(ii) = matchedFrameCount(ii) / max(expectedProtocolFrameCount, eps);
        packetSuccessRate(ii) = validPacketCount(ii) / max(expectedOtaPacketCount, eps);
        bestBitShiftVec(ii) = best.bitShift;
        totalBerVec(ii) = best.totalBer;

        if matchedFrameCount(ii) > 0
            fprintf("Eb/N0=%5.1f dB | OTA=%d | 匹配帧=%d | 帧成功率=%.3f | bitShift=%d | BER=%g\n", ...
                EbN0dB, validPacketCount(ii), matchedFrameCount(ii), frameSuccessRate(ii), ...
                best.bitShift, best.totalBer);

            if ii == midIdx || ii == numel(EbN0dB_vec)
                fprintf("  解码帧示例：\n");
                local_print_frame_examples(best.frames, txData.protocolFrames, 3);
            end
        else
            fprintf("Eb/N0=%5.1f dB | OTA=%d | 匹配帧=%d | 帧成功率=%.3f | bitShift=%d | 解码失败\n", ...
                EbN0dB, validPacketCount(ii), matchedFrameCount(ii), frameSuccessRate(ii), ...
                best.bitShift);
        end

        if showPlots && ii == midIdx
            local_show_rx_snapshot(r, m_hat, bitMetricStream, best, Fs, EbN0dB);
        end
    end

    if showPlots
        figure('Name', '仿真统计');
        subplot(2,3,1);
        plot(EbN0dB_vec, matchedFrameCount, '-o'); grid on;
        xlabel('Eb/N0 (dB)'); ylabel('匹配协议帧数量');
        title('匹配协议帧');

        subplot(2,3,2);
        plot(EbN0dB_vec, validPacketCount, '-o'); grid on;
        xlabel('Eb/N0 (dB)'); ylabel('有效 OTA 包数量');
        title('OTA 包解出数量');

        subplot(2,3,3);
        plot(EbN0dB_vec, frameSuccessRate, '-o'); grid on;
        xlabel('Eb/N0 (dB)'); ylabel('帧成功率');
        ylim([-0.02 1.02]);
        title('协议帧成功率');

        subplot(2,3,4);
        plot(EbN0dB_vec, packetSuccessRate, '-o'); grid on;
        xlabel('Eb/N0 (dB)'); ylabel('包成功率');
        ylim([-0.02 1.02]);
        title('OTA 包成功率');

        subplot(2,3,5);
        plot(EbN0dB_vec, bestBitShiftVec, '-o'); grid on;
        xlabel('Eb/N0 (dB)'); ylabel('最优 bitShift');
        title('最优比特移位');
    end

    simResult = struct( ...
        'cfg', cfg, ...
        'txData', txData, ...
        'validFrameCount', validFrameCount, ...
        'matchedFrameCount', matchedFrameCount, ...
        'validPacketCount', validPacketCount, ...
        'frameSuccessRate', frameSuccessRate, ...
        'packetSuccessRate', packetSuccessRate, ...
        'bestBitShiftVec', bestBitShiftVec, ...
        'totalBerVec', totalBerVec);
end

function local_print_frame_examples(frames, expectedFrames, maxCount)
    printed = 0;
    for k = 1:numel(frames)
        fr = frames(k).result;
        [payloadMatch, payloadDetail] = protocol_payload_matches_expected(fr, expectedFrames);
        fprintf("    seq=%d | cmdId=0x%04X | type=%s | match=%d | detail=%s\n", ...
            fr.seq, fr.cmdId, fr.type, payloadMatch, payloadDetail);
        fprintf("      %s\n", protocol_frame_to_text(fr));
        printed = printed + 1;
        if printed >= maxCount
            break;
        end
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

    figure('Name', 'TX 细节');
    subplot(2,2,1);
    stem(txData.h_gauss, 'filled'); grid on;
    xlabel('Tap'); ylabel('Amplitude');
    title(sprintf('Gaussian Taps | BT=%.2f, span=%d', cfg.bt, cfg.gaussianSpan));

    subplot(2,2,2);
    plot(fAxis/1e3, Hdb, 'LineWidth', 1.1); grid on;
    xlabel('Frequency (kHz)'); ylabel('Magnitude (dB)');
    title('Gaussian Filter Response');

    subplot(2,2,3);
    stairs(tShowMs, txData.bitWave(1:nShowWave), 'LineWidth', 1.0); hold on;
    plot(tShowMs, txData.shapedControl(1:nShowWave), 'LineWidth', 1.2);
    hold off; grid on;
    xlabel('Time (ms)'); ylabel('Level');
    legend('NRZ', 'Gaussian-shaped', 'Location', 'best');
    title('Frequency Control Signal');

    subplot(2,2,4);
    plot(tShowMs, instFreqHz(1:nShowWave)/1e3, 'LineWidth', 1.2); grid on;
    xlabel('Time (ms)'); ylabel('kHz');
    title('Instantaneous Frequency');

    figure('Name', 'TX 概览');
    subplot(3,2,1);
    stairs(txData.bits(1:min(192,end)), 'LineWidth', 1.0); grid on;
    xlabel('Bit Index'); ylabel('Bit');
    ylim([-0.2 1.2]);
    title('OTA Bit Stream');

    subplot(3,2,2);
    stem(double(txData.cycleSpec.otaSpec.packets(1).packetBytes), 'filled'); grid on;
    xlabel('Byte Index'); ylabel('Value');
    title('First OTA Packet Bytes');

    subplot(3,2,3);
    plot(tMs(1:min(1200,end)), txData.phi(1:min(1200,end)), 'LineWidth', 1.1); grid on;
    xlabel('Time (ms)'); ylabel('Phase (rad)');
    title('Continuous Phase');

    subplot(3,2,4);
    plot(real(txData.s_bb(1:min(1200,end))), 'LineWidth', 1.0); hold on;
    plot(imag(txData.s_bb(1:min(1200,end))), 'LineWidth', 1.0);
    hold off; grid on;
    xlabel('Sample'); ylabel('Amplitude');
    legend('I', 'Q', 'Location', 'best');
    title('TX IQ Waveform');

    subplot(3,2,5);
    plot(real(txData.s_bb(1:min(4000,end))), imag(txData.s_bb(1:min(4000,end))), '.');
    axis equal; grid on;
    xlabel('I'); ylabel('Q');
    title('TX IQ Constellation');

    subplot(3,2,6);
    [fAxisTx, psdTx] = simple_spectrum_db(txData.s_bb, cfg.Fs, 8192);
    plot(fAxisTx/1e3, psdTx, 'LineWidth', 1.1); grid on;
    xlabel('Frequency (kHz)'); ylabel('Magnitude (dB)');
    title('TX Spectrum');
end

function local_show_rx_snapshot(r, m_hat, bitMetricStream, best, Fs, EbN0dB)
    figure('Name', '接收快照');
    subplot(3,2,1);
    plot(real(r(1:min(4000,end))), imag(r(1:min(4000,end))), '.');
    axis equal; grid on;
    title(sprintf('接收 IQ | Eb/N0=%g dB', EbN0dB));

    subplot(3,2,2);
    [fAxisRx, psdRx] = simple_spectrum_db(r, Fs, 8192);
    plot(fAxisRx/1e3, psdRx, 'LineWidth', 1.1); grid on;
    xlabel('频率 (kHz)'); ylabel('幅度 (dB)');
    title('接收频谱');

    subplot(3,2,3);
    plot(m_hat(1:min(5000,end)), 'LineWidth', 1.1); grid on;
    xlabel('采样点'); ylabel('归一化频偏');
    title('鉴频输出');

    subplot(3,2,4);
    plot(bitMetricStream(1:min(5000,end)), 'LineWidth', 1.1); grid on;
    xlabel('采样点'); ylabel('平均电平');
    title('过零同步后 bit 统计量');

    subplot(3,2,5);
    stairs(best.bitsHat(1:min(200,end)), 'LineWidth', 1.2); grid on;
    xlabel('比特索引'); ylabel('判决值');
    ylim([-0.2 1.2]);
    title(sprintf('恢复比特流 | bitShift=%d', best.bitShift));

    subplot(3,2,6);
    if ~isempty(best.frames)
        cmdIds = arrayfun(@(x) double(x.result.cmdId), best.frames);
        stem(cmdIds, 'filled'); grid on;
        xlabel('协议帧序号'); ylabel('cmdId');
        title('有效协议帧 cmdId');
    else
        text(0.1, 0.5, '未找到有效协议帧', 'FontSize', 12);
        axis off;
    end
end
