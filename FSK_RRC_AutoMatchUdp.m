function state = FSK_RRC_AutoMatchUdp(varargin)
    % Main-program aligned UDP automation for the GFSK receiver.
    %
    % UDP input is driver.referee.udp_protocol.SendMsgBag:
    %   Byte 0 bit 0-3: game_progress
    %   Byte 1        : robot_id
    %   Byte 2 bit 0-1: own_encrypt_level
    %   Byte 2 bit 2  : is_key_changeable
    %
    % UDP output is driver.referee.udp_protocol.RecvMsgBag:
    %   Byte 0        : reserved/prefix, default 0
    %   Byte 1-6      : 6-byte jammer key
    project_setup();
    close all;

    cfgDefault = FSK_RRC_ProjectConfig();
    rxCfg = cfgDefault.rx;
    infoCaptureSampleRateDefault = rxCfg.InfoCaptureSampleRateHz;
    infoCaptureSampleRateEnv = str2double(getenv('INFO_CAPTURE_SAMPLE_RATE_HZ'));
    if isfinite(infoCaptureSampleRateEnv) && infoCaptureSampleRateEnv >= 2 * 270e3
        infoCaptureSampleRateDefault = infoCaptureSampleRateEnv;
    end

    p = inputParser;
    addParameter(p, 'ListenPort', 5006);
    addParameter(p, 'KeyRemoteHost', "127.0.0.1");
    addParameter(p, 'KeyRemotePort', 5007);
    addParameter(p, 'InfoRemoteHost', "");
    addParameter(p, 'InfoRemotePort', []);
    addParameter(p, 'RunTimeSec', inf);
    addParameter(p, 'SocketTimeoutSec', 0.2);
    addParameter(p, 'MaxDatagramBytes', 3);
    addParameter(p, 'DecodeInfo', true);
    addParameter(p, 'DecodeJammer', true);
    addParameter(p, 'JammerCaptureTimeSec', 1.5);
    addParameter(p, 'InfoSendIntervalSec', 0.1);
    addParameter(p, 'InfoStreamDecodeWindowSec', 0.25);
    addParameter(p, 'InfoStreamDecodeStrideSec', 0.10);
    addParameter(p, 'InfoStreamRingBufferSec', 1.0);
    addParameter(p, 'InfoStreamMaxPendingWindows', 64);
    addParameter(p, 'InfoStreamWorkerCount', 2);
    addParameter(p, 'InfoFreshWindowSec', 3.0);
    addParameter(p, 'JammerRetryIntervalSec', 1.0);
    addParameter(p, 'KeyRepeatIntervalSec', 0.1);
    addParameter(p, 'ActiveKeyRepeatIntervalSec', 0.5);
    addParameter(p, 'SuppressRecvConsole', true);
    addParameter(p, 'EnablePlutoRx', rxCfg.EnablePlutoRx);
    addParameter(p, 'ReusePlutoRx', true);
    addParameter(p, 'PrewarmInfoBeforeMatch', true);
    addParameter(p, 'PrewarmJammerBeforeMatch', true);
    % 正式比赛固定分工：2.1 接收信息波，3.1 接收干扰波。
    addParameter(p, 'InfoRxRadioID', "ip:192.168.2.1");
    addParameter(p, 'JammerRxRadioID', "ip:192.168.3.1");
    addParameter(p, 'InfoCenterFrequencyOffsetHz', rxCfg.RxCenterFrequencyOffsetHz);
    addParameter(p, 'JammerCenterFrequencyOffsetHz', 0);
    addParameter(p, 'FailoverRole', "fixed");
    addParameter(p, 'RadioCheckIntervalSec', 2.0);
    addParameter(p, 'JammerInputSamples', []);
    addParameter(p, 'JammerInputSampleRateHz', []);
    addParameter(p, 'UseAGC', rxCfg.UseAGC);
    addParameter(p, 'AGCMode', rxCfg.AGCMode);
    addParameter(p, 'RxGain_dB', rxCfg.RxGain_dB);
    addParameter(p, 'CaptureSampleRateHz', rxCfg.CaptureSampleRateHz);
    addParameter(p, 'InfoCaptureSampleRateHz', infoCaptureSampleRateDefault);
    addParameter(p, 'RxRFBandwidthHz', rxCfg.RxRFBandwidthHz);
    addParameter(p, 'SamplesPerFrame', rxCfg.SamplesPerFrame);
    addParameter(p, 'WarmupFrames', rxCfg.WarmupFrames);
    addParameter(p, 'InfoPreDemodChannelCutoffHz', 270e3);
    addParameter(p, 'InfoPreDemodChannelFilterOrder', 240);
    addParameter(p, 'InfoQuadratureDemodGain', 1.5);
    addParameter(p, 'InfoSymbolSyncLoopBandwidth', 0.005);
    addParameter(p, 'InfoSymbolSyncDampingFactor', 1.0);
    addParameter(p, 'InfoSymbolSyncDetectorGain', 1.0);
    addParameter(p, 'JammerPreDemodChannelCutoffHz', []);
    addParameter(p, 'JammerPreDemodChannelFilterOrder', 240);
    addParameter(p, 'JammerQuadratureDemodGain', 1.5);
    addParameter(p, 'JammerSymbolSyncLoopBandwidth', 0.005);
    addParameter(p, 'JammerSymbolSyncDampingFactor', 1.0);
    addParameter(p, 'JammerSymbolSyncDetectorGain', 1.0);
    addParameter(p, 'ShowRecvPlots', false);
    parse(p, varargin{:});
    opt = local_normalize_options(p.Results);

    rxSocket = local_create_udp_socket(opt.ListenPort, opt.SocketTimeoutSec);
    % 每次 Pluto 帧之间快速轮询比赛状态，避免 socket 等待制造采集空窗。
    rxSocket.setSoTimeout(int32(1));
    txSocket = javaObject('java.net.DatagramSocket');
    cleanupObj = onCleanup(@() local_close_udp_sockets(rxSocket, txSocket));
    plutoCleanupObj = onCleanup(@() reusable_pluto_rx("release"));

    state = local_initial_state(opt);
    local_print_banner(opt);

    loopStart = tic;
    while true
        if isfinite(opt.RunTimeSec) && toc(loopStart) >= opt.RunTimeSec
            break;
        end

        [statusBytes, senderText, gotMessage, drainCount] = local_receive_latest_udp_bytes(rxSocket, opt.MaxDatagramBytes);
        if gotMessage
            if drainCount > 1
                fprintf('[%s] status udp backlog drained: count=%d latest_from=%s latest_raw=%s\n', ...
                    local_clock_text(), drainCount, senderText, local_bytes_to_hex(statusBytes));
            end
            state = local_update_status(statusBytes, senderText, state, opt);
        end

        if state.hasStatus
            state = local_run_due_actions(state, opt, txSocket);
        else
            pause(0.005);
        end
    end

    state = local_stop_info_receiver(state, "auto_match_stopped");
    fprintf('[%s] Auto match UDP stopped. info_frames=%d key_success=%d errors=%d\n', ...
        local_clock_text(), state.infoFrameCount, state.keySuccessCount, state.errorCount);
end

function opt = local_normalize_options(opt)
    opt.ListenPort = double(opt.ListenPort);
    opt.KeyRemoteHost = string(opt.KeyRemoteHost);
    opt.KeyRemotePort = double(opt.KeyRemotePort);
    opt.InfoRemoteHost = string(opt.InfoRemoteHost);
    if strlength(strtrim(opt.InfoRemoteHost)) == 0
        opt.InfoRemoteHost = opt.KeyRemoteHost;
    end
    if isempty(opt.InfoRemotePort)
        opt.InfoRemotePort = opt.KeyRemotePort;
    end
    opt.InfoRemotePort = double(opt.InfoRemotePort);
    opt.RunTimeSec = double(opt.RunTimeSec);
    opt.SocketTimeoutSec = double(opt.SocketTimeoutSec);
    opt.MaxDatagramBytes = double(opt.MaxDatagramBytes);
    opt.DecodeInfo = logical(opt.DecodeInfo);
    opt.DecodeJammer = logical(opt.DecodeJammer);
    opt.JammerCaptureTimeSec = double(opt.JammerCaptureTimeSec);
    opt.InfoSendIntervalSec = double(opt.InfoSendIntervalSec);
    opt.InfoStreamDecodeWindowSec = max(0.05, double(opt.InfoStreamDecodeWindowSec));
    opt.InfoStreamDecodeStrideSec = max(0.025, double(opt.InfoStreamDecodeStrideSec));
    opt.InfoStreamRingBufferSec = max( ...
        opt.InfoStreamDecodeWindowSec, double(opt.InfoStreamRingBufferSec));
    opt.InfoStreamMaxPendingWindows = max(1, round(double(opt.InfoStreamMaxPendingWindows)));
    opt.InfoStreamWorkerCount = max(1, round(double(opt.InfoStreamWorkerCount)));
    opt.InfoFreshWindowSec = max(0.05, double(opt.InfoFreshWindowSec));
    opt.JammerRetryIntervalSec = double(opt.JammerRetryIntervalSec);
    opt.KeyRepeatIntervalSec = double(opt.KeyRepeatIntervalSec);
    opt.ActiveKeyRepeatIntervalSec = double(opt.ActiveKeyRepeatIntervalSec);
    opt.SuppressRecvConsole = logical(opt.SuppressRecvConsole);
    opt.EnablePlutoRx = logical(opt.EnablePlutoRx);
    opt.ReusePlutoRx = logical(opt.ReusePlutoRx);
    opt.PrewarmInfoBeforeMatch = logical(opt.PrewarmInfoBeforeMatch);
    opt.PrewarmJammerBeforeMatch = logical(opt.PrewarmJammerBeforeMatch);
    opt.InfoRxRadioID = string(opt.InfoRxRadioID);
    opt.JammerRxRadioID = string(opt.JammerRxRadioID);
    opt.InfoCenterFrequencyOffsetHz = double(opt.InfoCenterFrequencyOffsetHz);
    opt.JammerCenterFrequencyOffsetHz = double(opt.JammerCenterFrequencyOffsetHz);
    if ~isscalar(opt.InfoCenterFrequencyOffsetHz) || ~isfinite(opt.InfoCenterFrequencyOffsetHz) || ...
            ~isscalar(opt.JammerCenterFrequencyOffsetHz) || ~isfinite(opt.JammerCenterFrequencyOffsetHz)
        error('信息波和干扰波中心频率偏移必须是有限标量。');
    end
    opt.FailoverRole = lower(strtrim(string(opt.FailoverRole)));
    opt.RadioCheckIntervalSec = max(0.2, double(opt.RadioCheckIntervalSec));
    opt.CaptureSampleRateHz = double(opt.CaptureSampleRateHz);
    opt.InfoCaptureSampleRateHz = double(opt.InfoCaptureSampleRateHz);
    if ~isscalar(opt.InfoCaptureSampleRateHz) || ...
            ~isfinite(opt.InfoCaptureSampleRateHz) || ...
            opt.InfoCaptureSampleRateHz < 2 * 270e3
        error('InfoCaptureSampleRateHz 必须是不小于 540 kHz 的有限标量。');
    end
    opt.RxRFBandwidthHz = local_normalize_optional_positive_double(opt.RxRFBandwidthHz);
    opt.SamplesPerFrame = double(opt.SamplesPerFrame);
    opt.WarmupFrames = double(opt.WarmupFrames);
    opt.RxGain_dB = double(opt.RxGain_dB);
    opt.AGCMode = lower(strtrim(string(opt.AGCMode)));
    if opt.AGCMode == "slow_attack"
        opt.AGCMode = "slow";
    elseif opt.AGCMode == "fast_attack"
        opt.AGCMode = "fast";
    end
    if ~ismember(opt.AGCMode, ["slow", "fast"])
        error('AGCMode 仅支持 slow 或 fast，当前值：%s。', opt.AGCMode);
    end
    opt.InfoPreDemodChannelCutoffHz = double(opt.InfoPreDemodChannelCutoffHz);
    opt.InfoPreDemodChannelFilterOrder = double(opt.InfoPreDemodChannelFilterOrder);
    opt.InfoQuadratureDemodGain = double(opt.InfoQuadratureDemodGain);
    opt.InfoSymbolSyncLoopBandwidth = double(opt.InfoSymbolSyncLoopBandwidth);
    opt.InfoSymbolSyncDampingFactor = double(opt.InfoSymbolSyncDampingFactor);
    opt.InfoSymbolSyncDetectorGain = double(opt.InfoSymbolSyncDetectorGain);
    opt.JammerPreDemodChannelCutoffHz = local_normalize_optional_positive_double( ...
        opt.JammerPreDemodChannelCutoffHz);
    opt.JammerPreDemodChannelFilterOrder = double(opt.JammerPreDemodChannelFilterOrder);
    opt.JammerQuadratureDemodGain = double(opt.JammerQuadratureDemodGain);
    opt.JammerSymbolSyncLoopBandwidth = double(opt.JammerSymbolSyncLoopBandwidth);
    opt.JammerSymbolSyncDampingFactor = double(opt.JammerSymbolSyncDampingFactor);
    opt.JammerSymbolSyncDetectorGain = double(opt.JammerSymbolSyncDetectorGain);
    opt.ShowRecvPlots = logical(opt.ShowRecvPlots);
end

function state = local_initial_state(opt)
    state = struct();
    state.listenPort = opt.ListenPort;
    state.hasStatus = false;
    state.lastStatus = struct();
    state.lastStatusSource = "";
    state.lastStatusLogTic = [];
    state.lastInfoSourceName = "";
    state.lastJammerSourceName = "";
    state.lastInfoAttemptTic = [];
    state.lastJammerPrewarmTic = [];
    state.jammerPrewarmedSourceName = "";
    state.lastJammerAttemptTic = [];
    state.lastJammerSkipLogTic = [];
    state.lastJammerAttemptKey = "";
    state.lastJammerReceiverSourceName = "";
    state.lastReceiverSourceName = "";
    state.lastReceiverRadioID = "";
    state.lastKeyRepeatTic = [];
    state.activeJammerSourceName = "";
    state.activeJammerLevel = 0;
    state.activeJammerKey = "";
    state.activeJammerPayload = uint8([]);
    state.maxSolvedJammerLevel = 0;
    state.sentKeyTexts = strings(0, 1);
    state.solvedJammerSources = strings(0, 1);
    state.infoState = struct();
    state.infoReceiver = [];
    state.infoStreamFinalStats = struct();
    state.infoStreamLastStatsLogTic = [];
    state.infoStreamDecodeCount = 0;
    state.infoStreamUpdateCount = 0;
    state.infoCmdPayloads = zeros(local_info_payload_total_length(), 1, 'uint8');
    state.infoCmdValid = false(5, 1);
    state.infoCmdLastUpdateTic = cell(5, 1);
    state.infoCmdHasIdentity = false(5, 1);
    state.infoCmdLastAcceptedSeq = zeros(5, 1, 'uint8');
    state.infoCmdProcessedWindowEnd = zeros(5, 1);
    state.infoCmdAcceptedCount = zeros(5, 1);
    state.infoDuplicateDropCount = 0;
    state.infoStaleWindowDropCount = 0;
    state.infoFreshWindowSec = opt.InfoFreshWindowSec;
    state.infoSnapshotSeq = uint16(0);
    state.infoSnapshotUpdateIndex = uint8(0);
    state.infoSnapshotPayload = local_pack_info_snapshot(state);
    state.infoCaptureCount = 0;
    state.infoFrameCount = 0;
    state.infoUpdateCount = 0;
    state.infoSendCount = 0;
    state.lastInfoSendTic = [];
    state.keyAttemptCount = 0;
    state.keySuccessCount = 0;
    state.keyRepeatCount = 0;
    state.sentKeyPayloads = strings(0, 1);
    state.lastError = "";
    state.errorCount = 0;
    state.lastRadioCheckTic = [];
    state.infoRadioOnline = true;
    state.jammerRadioOnline = true;
    state.infoRadioProbe = local_empty_radio_probe();
    state.jammerRadioProbe = local_empty_radio_probe();
end

function local_print_banner(opt)
    fprintf('\n=== Main UDP Aligned GFSK Receiver ===\n');
    fprintf('status_listen=0.0.0.0:%d SendMsgBag(3 bytes)\n', opt.ListenPort);
    fprintf('key_output=%s:%d RecvMsgBag(7 bytes)\n', opt.KeyRemoteHost, opt.KeyRemotePort);
    fprintf('info_output=%s:%d InfoMsgBag v3(102 bytes, fresh_window=%.3f s)\n', ...
        opt.InfoRemoteHost, opt.InfoRemotePort, opt.InfoFreshWindowSec);
    fprintf('info_rx=%s jammer_rx=%s\n', opt.InfoRxRadioID, opt.JammerRxRadioID);
    fprintf('failover_role=%s radio_check_interval=%.3f s\n', opt.FailoverRole, opt.RadioCheckIntervalSec);
    fprintf(['info_window=%.3f s stride=%.3f s ring=%.3f s ' ...
        'max_pending=%d workers=%d\n'], ...
        opt.InfoStreamDecodeWindowSec, ...
        opt.InfoStreamDecodeStrideSec, opt.InfoStreamRingBufferSec, ...
        opt.InfoStreamMaxPendingWindows, opt.InfoStreamWorkerCount);
    if isempty(opt.RxRFBandwidthHz) || opt.RxRFBandwidthHz <= 0
        rfBandwidthText = "strict_by_source";
    else
        rfBandwidthText = sprintf("%.3f MHz override", opt.RxRFBandwidthHz / 1e6);
    end
    fprintf(['info_capture_sample_rate=%.3f MHz jammer_capture_sample_rate=%.3f MHz ' ...
        'rx_rf_bandwidth=%s decode_sample_rate=1.000 MHz\n\n'], ...
        opt.InfoCaptureSampleRateHz / 1e6, ...
        opt.CaptureSampleRateHz / 1e6, rfBandwidthText);
end

function value = local_normalize_optional_positive_double(value)
    if isempty(value)
        value = [];
        return;
    end
    value = double(value);
    if ~isfinite(value) || value <= 0
        value = [];
    end
end

function state = local_update_status(rawBytes, senderText, state, opt)
    [status, ok, parseError] = local_parse_main_status(rawBytes);
    if ~ok
        state = local_record_error(state, "status_parse_failed:" + parseError);
        fprintf('[%s] status ignored: %s | from=%s | raw=%s\n', ...
            local_clock_text(), parseError, senderText, local_bytes_to_hex(rawBytes));
        return;
    end

    [shouldReset, resetReason] = local_should_reset_match_cache(state, status);
    if shouldReset
        preserveInfoReceiver = status.gameStarted && ...
            isfield(state, 'infoReceiver') && ~isempty(state.infoReceiver);
        state = local_reset_match_state(state, preserveInfoReceiver);
        fprintf('[%s] match cache reset: %s\n', local_clock_text(), resetReason);
    end

    if state.hasStatus && isfield(state.lastStatus, 'gameStarted')
        oldStatus = state.lastStatus;
        if oldStatus.gameStarted && status.gameStarted && ...
                isfield(oldStatus, 'jammerLevel') && oldStatus.jammerLevel ~= status.jammerLevel
            state = local_clear_active_jammer_key(state);
            fprintf('[%s] jammer level changed: %d -> %d\n', ...
                local_clock_text(), oldStatus.jammerLevel, status.jammerLevel);
        end
        if oldStatus.gameStarted && status.gameStarted && ...
                isfield(oldStatus, 'teamColor') && string(oldStatus.teamColor) ~= string(status.teamColor)
            state = local_clear_active_jammer_key(state);
            fprintf('[%s] team color changed: %s -> %s\n', ...
                local_clock_text(), string(oldStatus.teamColor), string(status.teamColor));
        end
    end

    if ~status.gameStarted && ...
            (strlength(state.activeJammerKey) > 0 || strlength(state.activeJammerSourceName) > 0)
        state = local_clear_active_jammer_key(state);
        fprintf('[%s] match not running, stop repeating jammer key.\n', local_clock_text());
    end

    statusChanged = ~state.hasStatus || ~isfield(state.lastStatus, 'rawBytes') || ...
        ~isequal(uint8(state.lastStatus.rawBytes(:)), uint8(status.rawBytes(:)));
    state.hasStatus = true;
    state.lastStatus = status;
    state.lastStatusSource = string(senderText);
    if statusChanged || local_due(state.lastStatusLogTic, 1.0)
        state.lastStatusLogTic = tic;
        fprintf('[%s] status updated: stage=%d started=%d robot_id=%d team=%s encrypt_level=%d key_changeable=%d from=%s\n', ...
            local_clock_text(), status.gameProgress, status.gameStarted, status.robotId, ...
            status.teamColor, status.jammerLevel, status.canModifyKey, senderText);
    end
end

function [status, ok, err] = local_parse_main_status(rawBytes)
    rawBytes = uint8(rawBytes(:).');
    status = struct( ...
        'rawBytes', rawBytes, ...
        'gameStarted', false, ...
        'gameProgress', 0, ...
        'teamColor', "", ...
        'robotId', [], ...
        'jammerLevel', 0, ...
        'canModifyKey', false);
    ok = false;
    err = "";

    if numel(rawBytes) ~= 3
        err = sprintf("invalid_SendMsgBag_size:%d", numel(rawBytes));
        return;
    end

    status.gameProgress = double(bitand(rawBytes(1), uint8(15)));
    status.gameStarted = status.gameProgress == 4;
    status.robotId = double(rawBytes(2));
    status.teamColor = local_color_from_robot_id(status.robotId);
    status.jammerLevel = double(bitand(rawBytes(3), uint8(3)));
    status.canModifyKey = bitand(rawBytes(3), uint8(4)) ~= 0;

    if status.gameStarted && strlength(status.teamColor) == 0
        err = "missing_or_unknown_team_color";
        return;
    end

    ok = true;
end

function [tf, reason] = local_should_reset_match_cache(state, newStatus)
    tf = false;
    reason = "";
    if ~state.hasStatus
        if newStatus.gameStarted
            tf = true;
            reason = "first_running_status";
        end
        return;
    end

    oldStatus = state.lastStatus;
    if isfield(oldStatus, 'gameStarted') && ~oldStatus.gameStarted && newStatus.gameStarted
        tf = true;
        reason = "new_match_started";
        return;
    end

    if isfield(oldStatus, 'gameStarted') && oldStatus.gameStarted && ~newStatus.gameStarted
        tf = true;
        reason = "match_stopped";
        return;
    end

    if isfield(oldStatus, 'robotId') && oldStatus.robotId ~= newStatus.robotId
        tf = true;
        reason = "robot_id_changed";
    end
end

function state = local_reset_match_state(state, preserveInfoReceiver)
    if nargin < 2
        preserveInfoReceiver = false;
    end
    if preserveInfoReceiver
        try
            state.infoReceiver.reset_epoch();
        catch ME
            fprintf('[%s] info receiver epoch reset failed, restart required: %s\n', ...
                local_clock_text(), ME.message);
            state = local_stop_info_receiver(state, "epoch_reset_failed");
        end
    else
        state = local_stop_info_receiver(state, "match_cache_reset");
    end
    state = local_clear_active_jammer_key(state);
    state.solvedJammerSources = strings(0, 1);
    state.sentKeyTexts = strings(0, 1);
    state.maxSolvedJammerLevel = 0;
    state.infoState = struct();
    state.infoCmdPayloads = zeros(local_info_payload_total_length(), 1, 'uint8');
    state.infoCmdValid = false(5, 1);
    state.infoCmdLastUpdateTic = cell(5, 1);
    state.infoCmdHasIdentity = false(5, 1);
    state.infoCmdLastAcceptedSeq = zeros(5, 1, 'uint8');
    state.infoCmdProcessedWindowEnd = zeros(5, 1);
    state.infoCmdAcceptedCount = zeros(5, 1);
    state.infoDuplicateDropCount = 0;
    state.infoStaleWindowDropCount = 0;
    state.infoSnapshotSeq = uint16(0);
    state.infoSnapshotUpdateIndex = uint8(0);
    state.infoSnapshotPayload = local_pack_info_snapshot(state);
    state.infoUpdateCount = 0;
    state.infoStreamDecodeCount = 0;
    state.infoStreamUpdateCount = 0;
    state.infoStreamLastStatsLogTic = [];
    state.infoSendCount = 0;
    state.lastInfoSendTic = [];
    state.lastInfoAttemptTic = [];
    state.lastJammerAttemptTic = [];
    state.lastJammerSkipLogTic = [];
    state.lastJammerAttemptKey = "";
    % 注意：这里故意不清空 lastReceiverSourceName/lastReceiverRadioID。
    % 新小局若波源相同可直接复用；阵营、等级或接管职责变化时会按新配置重新连接。
end

function state = local_clear_active_jammer_key(state)
    state.lastKeyRepeatTic = [];
    state.activeJammerSourceName = "";
    state.activeJammerLevel = 0;
    state.activeJammerKey = "";
    state.activeJammerPayload = uint8([]);
end

function state = local_run_due_actions(state, opt, txSocket)
    status = state.lastStatus;
    if ~status.gameStarted
        keepInfoPrewarm = opt.PrewarmInfoBeforeMatch && ...
            opt.ReusePlutoRx && opt.DecodeInfo && opt.FailoverRole == "info_primary";
        if ~keepInfoPrewarm
            state = local_stop_info_receiver(state, "match_not_running");
        end
        state = local_prewarm_info_before_match(state, status, opt);
        state = local_prewarm_jammer_before_match(state, status, opt);
        return;
    end

    state = local_update_radio_status_if_due(state, opt);
    plan = local_build_failover_plan(state, status, opt);

    if opt.DecodeInfo
        infoAction = local_build_info_action(status);
        if infoAction.shouldRun && plan.infoAllowed
            infoAction.rxRadioID = plan.infoRadioID;
            state.lastInfoSourceName = infoAction.sourceName;
            state = local_send_info_snapshot_if_due(state, opt, txSocket);
            state = local_service_continuous_info(state, opt, txSocket, infoAction);
        elseif ~infoAction.shouldRun && local_due(state.lastInfoAttemptTic, 1.0)
            state = local_stop_info_receiver(state, "info_action_disabled");
            state.lastInfoAttemptTic = tic;
            fprintf('[%s] info skipped: %s\n', local_clock_text(), infoAction.reason);
        elseif ~plan.infoAllowed && local_due(state.lastInfoAttemptTic, 1.0)
            state = local_stop_info_receiver(state, plan.infoReason);
            state.lastInfoAttemptTic = tic;
            fprintf('[%s] info skipped: %s\n', local_clock_text(), plan.infoReason);
        end
    else
        state = local_stop_info_receiver(state, "decode_info_disabled");
    end

    if opt.DecodeJammer
        jammerAction = local_build_jammer_action(status);
        if jammerAction.shouldRun
            if strlength(state.activeJammerSourceName) > 0 && ...
                    state.activeJammerSourceName ~= jammerAction.sourceName
                fprintf('[%s] switch jammer source: %s -> %s\n', ...
                    local_clock_text(), state.activeJammerSourceName, jammerAction.sourceName);
                state = local_clear_active_jammer_key(state);
            end

            if strlength(state.activeJammerKey) > 0
                if local_due(state.lastKeyRepeatTic, opt.ActiveKeyRepeatIntervalSec)
                    state = local_repeat_active_jammer_key(state, opt, txSocket);
                end
            end
        end

        if jammerAction.shouldRun && plan.jammerAllowed && ...
                local_due(state.lastJammerAttemptTic, opt.JammerRetryIntervalSec)
            state.lastJammerAttemptTic = tic;
            state.lastJammerSourceName = jammerAction.sourceName;
            jammerAction.rxRadioID = plan.jammerRadioID;
            state = local_capture_and_forward_jammer(state, opt, txSocket, jammerAction);
        elseif ~jammerAction.shouldRun && status.jammerLevel ~= 0 && ...
                local_due(state.lastJammerSkipLogTic, 1.0)
            % 等级>=3表示干扰阶段完成。主循环会高速执行，必须限制这条
            % 状态日志为每秒一次，避免无业务动作时反而持续占用磁盘和CPU。
            state.lastJammerSkipLogTic = tic;
            fprintf('[%s] jammer skipped: %s\n', local_clock_text(), jammerAction.reason);
        elseif jammerAction.shouldRun && ~plan.jammerAllowed && local_due(state.lastJammerAttemptTic, opt.JammerRetryIntervalSec)
            state.lastJammerAttemptTic = tic;
            fprintf('[%s] jammer skipped: %s\n', local_clock_text(), plan.jammerReason);
        end
    end
end

function state = local_prewarm_jammer_before_match(state, status, opt)
    % 赛前只连接并预热干扰波 Pluto，不解析 0x0A06、不更新密钥、也不发送业务 UDP。
    % 裁判赛前已明确反馈 1/2 级时按当前等级预热；等级为 0 或旧局残留 >=3 时，
    % 按正式流程的起始一级预热，比赛开始后若实际等级不同会自动重新配置。
    if ~opt.PrewarmJammerBeforeMatch || ~opt.ReusePlutoRx || ~opt.EnablePlutoRx || ...
            ~opt.DecodeJammer || opt.FailoverRole ~= "jammer_primary"
        return;
    end
    if ~local_due(state.lastJammerPrewarmTic, 2.0)
        return;
    end
    state.lastJammerPrewarmTic = tic;

    targetColor = string(status.teamColor);
    if strlength(targetColor) == 0
        return;
    end

    prewarmLevel = double(status.jammerLevel);
    if ~ismember(prewarmLevel, [1 2])
        prewarmLevel = 1;
    end
    sourceName = string(sprintf('%s_l%d_jammer', targetColor, prewarmLevel));
    if string(state.lastReceiverSourceName) == sourceName && ...
            string(state.lastReceiverRadioID) == string(opt.JammerRxRadioID)
        return;
    end

    try
        sourceCfg = get_gfsk_source_config(sourceName);
        rfBandwidthHz = opt.RxRFBandwidthHz;
        if isempty(rfBandwidthHz)
            rfBandwidthHz = sourceCfg.rxBandwidth;
        end
        radioCtx = resolve_pluto_radio_id(opt.JammerRxRadioID, "rx");
        reusableCfg = struct( ...
            'radioID', string(radioCtx.resolvedRadioID), ...
            'centerFrequency', double(sourceCfg.fc + opt.JammerCenterFrequencyOffsetHz), ...
            'sampleRate', double(opt.CaptureSampleRateHz), ...
            'samplesPerFrame', double(opt.SamplesPerFrame), ...
            'useAGC', logical(opt.UseAGC), ...
            'agcMode', opt.AGCMode, ...
            'gainDB', double(opt.RxGain_dB), ...
            'rfBandwidthHz', double(rfBandwidthHz));
        prewarmTic = tic;
        [rx, reused] = reusable_pluto_rx("acquire", reusableCfg);
        if ~reused
            info(rx);
            for frameIdx = 1:opt.WarmupFrames
                rx();
            end
            apply_pluto_rx_rf_bandwidth(rx, radioCtx.resolvedRadioID, rfBandwidthHz);
        end
        clear rx;
        state.jammerPrewarmedSourceName = sourceName;
        state.lastJammerReceiverSourceName = sourceName;
        state.lastReceiverSourceName = sourceName;
        state.lastReceiverRadioID = string(opt.JammerRxRadioID);
        fprintf('[%s] jammer receiver prewarmed: source=%s level=%d radio=%s reused=%d elapsed=%.3f s; decode remains gated\n', ...
            local_clock_text(), sourceName, prewarmLevel, opt.JammerRxRadioID, reused, toc(prewarmTic));
    catch ME
        reusable_pluto_rx("release");
        state.lastJammerReceiverSourceName = "";
        state.lastReceiverSourceName = "";
        state.lastReceiverRadioID = "";
        fprintf('[%s] jammer receiver prewarm failed: %s\n', local_clock_text(), ME.message);
    end
end

function state = local_prewarm_info_before_match(state, status, opt)
    % 赛前启动 Pluto 和常驻解码进程，但只采集、不提交窗口。
    % 比赛开始时 reset_epoch() 清除赛前 IQ，因此解码仍严格由
    % game_progress==4 门控，且不必在开赛后再等待硬件和 worker 进程冷启动。
    if ~opt.PrewarmInfoBeforeMatch || ~opt.ReusePlutoRx || ~opt.DecodeInfo || ...
            opt.FailoverRole ~= "info_primary"
        return;
    end
    targetColor = string(status.teamColor);
    if strlength(targetColor) == 0
        return;
    end
    sourceName = string(sprintf('%s_broadcast', targetColor));

    action = struct( ...
        'shouldRun', true, ...
        'reason', "prewarm", ...
        'targetColor', targetColor, ...
        'sourceName', sourceName, ...
        'rxRadioID', string(opt.InfoRxRadioID));
    needsStart = isempty(state.infoReceiver);
    if ~needsStart
        try
            stats = state.infoReceiver.get_stats();
            needsStart = ~stats.running || ...
                string(stats.sourceName) ~= sourceName || ...
                string(stats.radioID) ~= string(opt.InfoRxRadioID);
        catch
            needsStart = true;
        end
    end
    if needsStart
        state = local_stop_info_receiver(state, "prewarm_receiver_restart");
        try
            state.infoReceiver = InfoWaveContinuousReceiver(action, opt);
            state.lastReceiverSourceName = sourceName;
            state.lastReceiverRadioID = string(opt.InfoRxRadioID);
            fprintf(['[%s] info continuous pipeline prewarmed: source=%s ' ...
                'radio=%s; results remain gated\n'], ...
                local_clock_text(), sourceName, opt.InfoRxRadioID);
        catch ME
            state.infoReceiver = [];
            state.lastReceiverSourceName = "";
            state.lastReceiverRadioID = "";
            state = local_record_error(state, ...
                "info_continuous_prewarm_failed:" + string(ME.message));
            fprintf('[%s] info continuous pipeline prewarm failed: %s\n', ...
                local_clock_text(), ME.message);
            return;
        end
    end
    try
        state.infoReceiver.step(false);
    catch ME
        state = local_record_error(state, ...
            "info_continuous_prewarm_step_failed:" + string(ME.message));
        fprintf('[%s] info continuous pipeline prewarm step failed: %s\n', ...
            local_clock_text(), ME.message);
        state = local_stop_info_receiver(state, "prewarm_step_failed");
    end
end

function state = local_update_radio_status_if_due(state, opt)
    if ~opt.EnablePlutoRx
        state.infoRadioOnline = true;
        state.jammerRadioOnline = true;
        return;
    end

    oldInfo = state.infoRadioOnline;
    oldJammer = state.jammerRadioOnline;
    [state.infoRadioOnline, state.infoRadioProbe] = local_poll_radio_probe( ...
        state.infoRadioProbe, opt.InfoRxRadioID, state.infoRadioOnline, ...
        opt.RadioCheckIntervalSec, "info");
    [state.jammerRadioOnline, state.jammerRadioProbe] = local_poll_radio_probe( ...
        state.jammerRadioProbe, opt.JammerRxRadioID, state.jammerRadioOnline, ...
        opt.RadioCheckIntervalSec, "jammer");

    if oldInfo ~= state.infoRadioOnline || oldJammer ~= state.jammerRadioOnline
        fprintf('[%s] radio status changed: info_rx=%s online=%d jammer_rx=%s online=%d\n', ...
            local_clock_text(), opt.InfoRxRadioID, state.infoRadioOnline, ...
            opt.JammerRxRadioID, state.jammerRadioOnline);
    end
end

function plan = local_build_failover_plan(state, status, opt)
    role = opt.FailoverRole;
    jammerNeeded = local_jammer_needed(status);
    jammerComplete = local_jammer_complete(state, status);

    plan = struct( ...
        'infoAllowed', false, ...
        'jammerAllowed', false, ...
        'infoRadioID', opt.InfoRxRadioID, ...
        'jammerRadioID', opt.JammerRxRadioID, ...
        'infoReason', "", ...
        'jammerReason', "");

    switch role
        case "fixed"
            plan.infoAllowed = state.infoRadioOnline;
            plan.jammerAllowed = state.jammerRadioOnline && ~jammerComplete;
            plan.infoReason = local_radio_skip_reason("info_primary_offline", opt.InfoRxRadioID, state.infoRadioOnline);
            if jammerComplete
                plan.jammerReason = "jammer_stage_complete";
            else
                plan.jammerReason = local_radio_skip_reason("jammer_primary_offline", opt.JammerRxRadioID, state.jammerRadioOnline);
            end

        case "jammer_primary"
            % 本进程只占用干扰波主板 2.1。正常解析干扰波；信息波主板掉线时，裁判反馈等级 >=3 后接管信息波。
            plan.infoRadioID = opt.JammerRxRadioID;
            plan.jammerRadioID = opt.JammerRxRadioID;
            plan.jammerAllowed = state.jammerRadioOnline && ~jammerComplete;
            plan.infoAllowed = state.jammerRadioOnline && ~state.infoRadioOnline && ...
                (~jammerNeeded || jammerComplete);
            if ~state.jammerRadioOnline
                plan.jammerReason = "own_jammer_radio_offline";
                plan.infoReason = "own_jammer_radio_offline";
            elseif jammerComplete
                plan.jammerReason = "jammer_stage_complete";
            else
                plan.jammerReason = "ok";
            end
            if state.infoRadioOnline
                plan.infoReason = "info_primary_radio_online";
            elseif jammerNeeded && ~jammerComplete
                plan.infoReason = "jammer_priority_until_level3";
            elseif ~state.jammerRadioOnline
                plan.infoReason = "own_jammer_radio_offline";
            else
                plan.infoReason = "ok";
            end

        case "info_primary"
            % 本进程只占用信息波主板 3.1。正常解析信息波；干扰波主板掉线且裁判反馈等级 <3 时接管干扰波。
            plan.infoRadioID = opt.InfoRxRadioID;
            plan.jammerRadioID = opt.InfoRxRadioID;
            plan.jammerAllowed = state.infoRadioOnline && ~state.jammerRadioOnline && ...
                jammerNeeded && ~jammerComplete;
            plan.infoAllowed = state.infoRadioOnline && ...
                (state.jammerRadioOnline || ~jammerNeeded || jammerComplete);
            if ~state.infoRadioOnline
                plan.infoReason = "own_info_radio_offline";
                plan.jammerReason = "own_info_radio_offline";
            elseif ~state.jammerRadioOnline && jammerNeeded && ~jammerComplete
                plan.infoReason = "jammer_priority_until_level3";
                plan.jammerReason = "ok";
            elseif jammerComplete
                plan.jammerReason = "jammer_stage_complete";
            elseif state.jammerRadioOnline
                plan.jammerReason = "jammer_primary_radio_online";
            else
                plan.jammerReason = "ok";
            end

        otherwise
            plan.infoReason = "unknown_failover_role";
            plan.jammerReason = "unknown_failover_role";
    end
end

function tf = local_jammer_needed(status)
    % 只在裁判系统反馈 1/2 级时解析干扰波；
    % 反馈 >=3 表示本局干扰波阶段已结束，单板接管时也应回到信息波。
    tf = ismember(status.jammerLevel, [1 2]);
end

function tf = local_jammer_complete(~, status)
    % 裁判系统反馈等级到 3 或以上后，不再解析干扰波。
    tf = status.jammerLevel >= 3;
end

function reason = local_radio_skip_reason(defaultReason, radioID, online)
    if online
        reason = "ok";
    else
        reason = sprintf("%s:%s", defaultReason, radioID);
    end
end

function probe = local_empty_radio_probe()
    probe = struct( ...
        'running', false, ...
        'resultPath', "", ...
        'lastStartTic', [], ...
        'consecutiveFailures', 0, ...
        'backoffLogged', false);
end

function [online, probe] = local_poll_radio_probe( ...
        probe, radioID, previousOnline, baseIntervalSec, label)
    % ping 必须在后台执行。掉线板连续失败三次后仅每60秒后台复查一次，
    % 既保留恢复能力，也绝不能暂停在线板的 Pluto rx() 连续采集。
    radioID = strtrim(string(radioID));
    online = previousOnline;
    if ~startsWith(radioID, "ip:")
        online = true;
        return;
    end

    ipAddr = char(extractAfter(radioID, "ip:"));
    if isempty(regexp(ipAddr, '^\d{1,3}(\.\d{1,3}){3}$', 'once'))
        online = false;
        probe.consecutiveFailures = max(3, probe.consecutiveFailures);
        return;
    end

    if probe.running && strlength(probe.resultPath) > 0 && ...
            isfile(char(probe.resultPath))
        resultText = strtrim(fileread(char(probe.resultPath)));
        delete(char(probe.resultPath));
        probe.running = false;
        probe.resultPath = "";
        probeOnline = strcmp(resultText, '0');
        online = probeOnline;
        if probeOnline
            probe.consecutiveFailures = 0;
            probe.backoffLogged = false;
        else
            probe.consecutiveFailures = probe.consecutiveFailures + 1;
            if probe.consecutiveFailures >= 3 && ~probe.backoffLogged
                fprintf(['[%s] radio probe suspended: role=%s radio=%s ' ...
                    'failures=%d; later checks run asynchronously every 60 s\n'], ...
                    local_clock_text(), label, radioID, ...
                    probe.consecutiveFailures);
                probe.backoffLogged = true;
            end
        end
    end

    if probe.running
        return;
    end

    probeIntervalSec = max(0.2, double(baseIntervalSec));
    if probe.consecutiveFailures >= 3
        probeIntervalSec = 60.0;
    end
    if ~local_due(probe.lastStartTic, probeIntervalSec)
        return;
    end

    resultPath = string(tempname('/dev/shm')) + ".radio_status";
    tempPath = resultPath + ".tmp";
    command = sprintf([ ...
        '(ping -q -c 1 -W 1 %s >/dev/null 2>&1; ' ...
        'printf ''%%d\n'' $? > ''%s''; mv -f ''%s'' ''%s'') ' ...
        '>/dev/null 2>&1 &'], ...
        ipAddr, char(tempPath), char(tempPath), char(resultPath));
    [launchCode, ~] = system(command);
    probe.lastStartTic = tic;
    if launchCode == 0
        probe.running = true;
        probe.resultPath = resultPath;
    else
        online = false;
        probe.consecutiveFailures = probe.consecutiveFailures + 1;
    end
end

function state = local_repeat_active_jammer_key(state, opt, txSocket)
    local_send_udp_bytes(txSocket, opt.KeyRemoteHost, opt.KeyRemotePort, state.activeJammerPayload);
    state.lastKeyRepeatTic = tic;
    state.keyRepeatCount = state.keyRepeatCount + 1;
    if mod(state.keyRepeatCount, 10) == 1
        fprintf('[%s] jammer key repeated: key=%s source=%s payload=%s repeat_count=%d\n', ...
            local_clock_text(), state.activeJammerKey, state.activeJammerSourceName, ...
            local_bytes_to_hex(state.activeJammerPayload), state.keyRepeatCount);
    end
end

function tf = local_due(lastTic, intervalSec)
    tf = isempty(lastTic) || toc(lastTic) >= intervalSec;
end

function state = local_service_continuous_info(state, opt, txSocket, action)
    sourceName = string(action.sourceName);
    radioID = local_action_radio_id(action, opt.InfoRxRadioID);
    needsStart = isempty(state.infoReceiver);
    if ~needsStart
        try
            stats = state.infoReceiver.get_stats();
            needsStart = ~stats.running || ...
                string(stats.sourceName) ~= sourceName || ...
                string(stats.radioID) ~= string(radioID);
        catch
            needsStart = true;
        end
    end

    if needsStart
        state = local_stop_info_receiver(state, "receiver_restart");
        action.rxRadioID = radioID;
        try
            state.infoReceiver = InfoWaveContinuousReceiver(action, opt);
            state.lastReceiverSourceName = sourceName;
            state.lastReceiverRadioID = string(radioID);
            state.lastInfoAttemptTic = tic;
        catch ME
            state.infoReceiver = [];
            state.lastReceiverSourceName = "";
            state.lastReceiverRadioID = "";
            state = local_record_error(state, ...
                "info_continuous_start_failed:" + string(ME.message));
            fprintf('[%s] info continuous receiver start failed: %s\n', ...
                local_clock_text(), ME.message);
            return;
        end
    end

    try
        [records, heartbeatDue] = state.infoReceiver.step();
    catch ME
        state = local_record_error(state, ...
            "info_continuous_capture_failed:" + string(ME.message));
        fprintf('[%s] info continuous capture failed: %s\n', ...
            local_clock_text(), ME.message);
        state = local_stop_info_receiver(state, "capture_failed");
        return;
    end

    if heartbeatDue
        state = local_send_info_snapshot_if_due(state, opt, txSocket);
    end
    for recordIdx = 1:numel(records)
        decoded = records(recordIdx).decoded;
        state.infoCaptureCount = state.infoCaptureCount + 1;
        state.infoStreamDecodeCount = state.infoStreamDecodeCount + 1;
        if ~decoded.ok
            state = local_record_error(state, ...
                "info_stream_decode_failed:" + string(decoded.errorText));
            fprintf('[%s] info stream decode failed: samples=%d-%d error=%s\n', ...
                local_clock_text(), records(recordIdx).windowStartSample, ...
                records(recordIdx).windowEndSample, decoded.errorText);
            continue;
        end

        rawUpdates = decoded.updates;
        state.infoFrameCount = state.infoFrameCount + decoded.validFrameCount;
        [state, updates, ~, ~] = ...
            filter_info_wave_updates( ...
                state, rawUpdates, records(recordIdx).windowEndSample);
        if ~isempty(updates)
            latestPayload = local_updates_to_latest_payload(updates);
            state.infoState = local_merge_info_state(state.infoState, latestPayload);
            for updateIdx = 1:numel(updates)
                % 每条 CRC 完整命令独立更新缓存。UDP 只由
                % 100 ms 固定节拍发送最新完整快照，禁止在解码
                % 结果处理路径临时插发，避免阻塞 Pluto 连续采集。
                state = local_update_info_snapshot(state, updates(updateIdx));
                state.infoStreamUpdateCount = state.infoStreamUpdateCount + 1;
            end
        end
        % 不在每个 100 ms 窗口打印长日志。worker 结果可能一次
        % 返回多条，连续 fprintf 会暂停下一次 Pluto rx()，造成
        % 本可避免的 overflow。帧数、命令计数和队列状态在下方
        % 每秒一次的汇总日志中输出。
    end

    if local_due(state.infoStreamLastStatsLogTic, 1.0)
        state.infoStreamLastStatsLogTic = tic;
        stats = state.infoReceiver.get_stats();
        state.infoStreamFinalStats = stats;
        fprintf(['[%s] info stream stats: source=%s radio=%s captured_frames=%d ' ...
            'captured_samples=%d submitted=%d completed=%d failed=%d pending=%d ' ...
            'saturated_steps=%d max_pending=%d max_submit_gap=%.3f s ' ...
            'overflow=%d decoded_windows=%d valid_frames=%d accepted_cmds=%s ' ...
            'duplicate_drops=%d stale_drops=%d valid_mask=0x%02X fresh_mask=0x%02X ' ...
            'elapsed=%.3f s\n'], ...
            local_clock_text(), stats.sourceName, stats.radioID, ...
            stats.capturedFrameCount, stats.totalCapturedSamples, ...
            stats.submittedWindowCount, stats.completedWindowCount, ...
            stats.failedWindowCount, stats.pendingWindowCount, ...
            stats.saturatedStepCount, stats.maxPendingObserved, ...
            stats.maxSubmitGapSec, stats.overflowCount, ...
            state.infoStreamDecodeCount, state.infoFrameCount, ...
            mat2str(state.infoCmdAcceptedCount(:).'), ...
            state.infoDuplicateDropCount, state.infoStaleWindowDropCount, ...
            local_info_valid_mask(state), local_info_fresh_mask(state), ...
            stats.elapsedSec);
    end
end

function latestPayload = local_updates_to_latest_payload(updates)
    latestPayload = struct();
    for updateIdx = 1:numel(updates)
        latestPayload.(char(updates(updateIdx).type)) = updates(updateIdx).dataBytes;
    end
end

function state = local_stop_info_receiver(state, reason)
    if ~isfield(state, 'infoReceiver') || isempty(state.infoReceiver)
        return;
    end
    try
        stats = state.infoReceiver.get_stats();
        state.infoStreamFinalStats = stats;
        fprintf(['[%s] info continuous receiver stopped: reason=%s source=%s ' ...
            'captured_frames=%d submitted=%d completed=%d failed=%d ' ...
            'saturated_steps=%d max_submit_gap=%.3f s overflow=%d\n'], ...
            local_clock_text(), string(reason), stats.sourceName, ...
            stats.capturedFrameCount, stats.submittedWindowCount, ...
            stats.completedWindowCount, stats.failedWindowCount, ...
            stats.saturatedStepCount, stats.maxSubmitGapSec, stats.overflowCount);
        state.infoReceiver.stop();
    catch ME
        fprintf('[%s] info continuous receiver stop warning: %s\n', ...
            local_clock_text(), ME.message);
    end
    state.infoReceiver = [];
end

function state = local_capture_and_forward_jammer(state, opt, txSocket, action)
    fprintf('[%s] jammer capture start: source=%s source_color=%s level=%d duration=%.3f s\n', ...
        local_clock_text(), action.sourceName, action.targetColor, action.jammerLevel, opt.JammerCaptureTimeSec);
    state.keyAttemptCount = state.keyAttemptCount + 1;
    rxRadioID = local_action_radio_id(action, opt.JammerRxRadioID);
    fprintf('[%s] jammer capture radio=%s\n', local_clock_text(), rxRadioID);
    if ~isfield(state, 'lastJammerReceiverSourceName') || ...
            string(state.lastJammerReceiverSourceName) ~= string(action.sourceName)
        local_reset_pluto_rx_for_jammer(sprintf('source_change:%s->%s', ...
            char(string(state.lastJammerReceiverSourceName)), char(string(action.sourceName))));
        state.lastJammerReceiverSourceName = string(action.sourceName);
    end

    try
        [result, recvConsole] = local_run_jammer_recv(action.sourceName, rxRadioID, ...
            opt.JammerCaptureTimeSec, opt.JammerInputSamples, opt.JammerInputSampleRateHz, ...
            opt, @local_jammer_heartbeat, opt.ActiveKeyRepeatIntervalSec);
        state.lastReceiverSourceName = string(action.sourceName);
        state.lastReceiverRadioID = string(rxRadioID);
    catch ME
        state.lastReceiverSourceName = "";
        state.lastReceiverRadioID = "";
        state = local_record_error(state, "jammer_recv_failed:" + string(ME.message));
        fprintf('[%s] jammer capture failed: %s\n', local_clock_text(), ME.message);
        return;
    end

    keyText = local_extract_jammer_key(result);
    if strlength(keyText) == 0
        fprintf('[%s] jammer key not found: source=%s valid_frames=%d ota=%d/%d\n', ...
            local_clock_text(), action.sourceName, result.best.validFrameCount, ...
            result.best.validPacketCount, result.expectedOtaPacketCount);
        return;
    end

    payload = local_pack_main_recv_key(keyText, uint8(2));
    isSameActiveKey = strlength(state.activeJammerKey) > 0 && ...
        string(state.activeJammerKey) == string(keyText) && ...
        string(state.activeJammerSourceName) == string(action.sourceName);
    shouldForwardNow = ~isSameActiveKey;

    state.lastJammerAttemptKey = keyText;
    state.activeJammerSourceName = action.sourceName;
    state.activeJammerLevel = action.jammerLevel;
    state.activeJammerKey = keyText;
    state.activeJammerPayload = payload;
    state.maxSolvedJammerLevel = max(state.maxSolvedJammerLevel, action.jammerLevel);

    if shouldForwardNow
        local_send_udp_bytes(txSocket, opt.KeyRemoteHost, opt.KeyRemotePort, payload);
        state.keySuccessCount = state.keySuccessCount + 1;
        state.lastKeyRepeatTic = tic;
        state.sentKeyTexts(end+1, 1) = keyText;
        state.solvedJammerSources(end+1, 1) = action.sourceName;
        state.sentKeyPayloads(end+1, 1) = local_bytes_to_hex(payload);

        if isSameActiveKey
            fprintf('[%s] jammer key forwarded duplicate: key=%s source=%s to=%s:%d payload=%s\n', ...
                local_clock_text(), keyText, action.sourceName, opt.KeyRemoteHost, opt.KeyRemotePort, local_bytes_to_hex(payload));
        else
            fprintf('[%s] jammer key forwarded: key=%s source=%s to=%s:%d payload=%s\n', ...
                local_clock_text(), keyText, action.sourceName, opt.KeyRemoteHost, opt.KeyRemotePort, local_bytes_to_hex(payload));
        end
    else
        fprintf('[%s] jammer key unchanged: key=%s source=%s continue_repeating=1\n', ...
            local_clock_text(), keyText, action.sourceName);
    end

    if ~opt.SuppressRecvConsole && strlength(string(recvConsole)) > 0
        fprintf('%s\n', recvConsole);
    end

    function local_jammer_heartbeat()
        % 已有可验证密钥时，采集新干扰波期间低频保活回传旧密钥；
        % 采集结束若解析到新密钥，会立即切换为新密钥。
        if strlength(state.activeJammerKey) > 0 && local_due(state.lastKeyRepeatTic, opt.ActiveKeyRepeatIntervalSec)
            state = local_repeat_active_jammer_key(state, opt, txSocket);
        end
    end
end

function radioID = local_action_radio_id(action, fallbackRadioID)
    if isfield(action, 'rxRadioID') && strlength(string(action.rxRadioID)) > 0
        radioID = string(action.rxRadioID);
    else
        radioID = string(fallbackRadioID);
    end
end

function [result, recvConsole] = local_run_jammer_recv(sourceName, radioID, captureTimeSec, inputSamples, inputSampleRateHz, opt, heartbeatFcn, heartbeatIntervalSec)
    if nargin < 7
        heartbeatFcn = [];
    end
    if nargin < 8 || isempty(heartbeatIntervalSec)
        heartbeatIntervalSec = opt.InfoSendIntervalSec;
    end
    if ~opt.ReusePlutoRx
        local_reset_pluto_rx_for_switch(sourceName, radioID);
    end
    recvArgs = { ...
        'SourceName', char(sourceName), ...
        'RxRadioID', char(radioID), ...
        'UseAGC', opt.UseAGC, ...
        'AGCMode', opt.AGCMode, ...
        'RxGain_dB', opt.RxGain_dB, ...
        'RxCenterFrequencyOffsetHz', opt.JammerCenterFrequencyOffsetHz, ...
        'RxRFBandwidthHz', opt.RxRFBandwidthHz, ...
        'SamplesPerFrame', opt.SamplesPerFrame, ...
        'WarmupFrames', opt.WarmupFrames, ...
        'CaptureTimeSec', captureTimeSec, ...
        'EnablePlutoRx', opt.EnablePlutoRx, ...
        'ReusePlutoRx', opt.ReusePlutoRx, ...
        'ShowPlots', opt.ShowRecvPlots, ...
        'PreDemodChannelCutoffHz', opt.JammerPreDemodChannelCutoffHz, ...
        'PreDemodChannelFilterOrder', opt.JammerPreDemodChannelFilterOrder, ...
        'QuadratureDemodGain', opt.JammerQuadratureDemodGain, ...
        'SymbolSyncLoopBandwidth', opt.JammerSymbolSyncLoopBandwidth, ...
        'SymbolSyncDampingFactor', opt.JammerSymbolSyncDampingFactor, ...
        'SymbolSyncDetectorGain', opt.JammerSymbolSyncDetectorGain};

    if ~isempty(heartbeatFcn)
        recvArgs = [recvArgs, { ...
            'HeartbeatFcn', heartbeatFcn, ...
            'HeartbeatIntervalSec', heartbeatIntervalSec}];
    end

    if ~isempty(inputSamples)
        recvArgs = [recvArgs, {'InputSamples', inputSamples}];
        if ~isempty(inputSampleRateHz)
            recvArgs = [recvArgs, {'CaptureSampleRateHz', double(inputSampleRateHz)}];
        end
    else
        recvArgs = [recvArgs, {'CaptureSampleRateHz', opt.CaptureSampleRateHz}];
    end

    if opt.SuppressRecvConsole
        recvConsole = evalc('result = FSK_RRC_Recv(recvArgs{:});');
    else
        result = FSK_RRC_Recv(recvArgs{:});
        recvConsole = "";
    end
end

function local_reset_pluto_rx_for_switch(sourceName, radioID)
    fprintf('[%s] pluto rx reset before capture: source=%s radio=%s\n', ...
        local_clock_text(), char(string(sourceName)), char(string(radioID)));
    try
        cleanup_pluto_workspace_objects();
    catch ME
        fprintf('[%s] pluto rx reset warning: %s\n', local_clock_text(), ME.message);
    end
    try
        reusable_pluto_rx("release");
    catch
    end
    try
        evalin('base', 'release(rx)');
    catch
    end
    try
        evalin('base', 'clear rx');
    catch
    end
    try
        evalin('base', 'clear tx');
    catch
    end
end

function local_reset_pluto_rx_for_jammer(reason)
    fprintf('[%s] jammer pluto rx reset: %s\n', local_clock_text(), reason);
    try
        cleanup_pluto_workspace_objects();
    catch ME
        fprintf('[%s] jammer pluto rx reset warning: %s\n', local_clock_text(), ME.message);
    end
    try
        reusable_pluto_rx("release");
    catch
    end
    % 新干扰源的中心频率和硬件带宽都不同，释放后留出设备重建窗口。
    pause(0.1);
    try
        evalin('base', 'clear rx');
    catch
    end
end

function action = local_build_info_action(status)
    action = struct('shouldRun', false, 'reason', "", 'sourceName', "", 'targetColor', "");
    targetColor = string(status.teamColor);
    if strlength(targetColor) == 0
        action.reason = "unknown_info_color_mode_or_team_color";
        return;
    end

    sourceName = sprintf("%s_broadcast", targetColor);
    try
        get_gfsk_source_config(sourceName);
    catch ME
        action.reason = string(ME.message);
        return;
    end

    action.shouldRun = true;
    action.reason = "ok";
    action.sourceName = string(sourceName);
    action.targetColor = targetColor;
end

function action = local_build_jammer_action(status)
    action = struct('shouldRun', false, 'reason', "", 'sourceName', "", 'targetColor', "", 'jammerLevel', nan);
    if status.jammerLevel >= 3
        action.reason = "jammer_level3_no_decode_needed";
        return;
    end

    if ~ismember(status.jammerLevel, [1 2])
        action.reason = "no_active_jammer_level";
        return;
    end

    targetColor = string(status.teamColor);
    if strlength(targetColor) == 0
        action.reason = "unknown_jammer_color_mode_or_team_color";
        return;
    end

    sourceName = sprintf("%s_l%d_jammer", targetColor, status.jammerLevel);
    try
        get_gfsk_source_config(sourceName);
    catch ME
        action.reason = string(ME.message);
        return;
    end

    action.shouldRun = true;
    action.reason = "ok";
    action.sourceName = string(sourceName);
    action.targetColor = targetColor;
    action.jammerLevel = status.jammerLevel;
end

function state = local_update_info_snapshot(state, updates)
    offsets = local_info_payload_offsets();
    lengths = local_info_payload_lengths();
    for k = 1:numel(updates)
        idx = updates(k).index;
        offset = offsets(idx);
        len = lengths(idx);
        state.infoCmdPayloads(offset:offset + len - 1) = uint8(updates(k).dataBytes(:));
        state.infoCmdValid(idx) = true;
        state.infoCmdLastUpdateTic{idx} = tic;
        state.infoCmdAcceptedCount(idx) = state.infoCmdAcceptedCount(idx) + 1;
        state.infoUpdateCount = state.infoUpdateCount + 1;
        % 0x0A01 是 0x0305 的正式坐标数据源。一个解码结果中后续字段
        % 不得覆盖其更新标记，否则“坐标内容未变化”的新帧无法续期250ms。
        if idx == 1 || state.infoSnapshotUpdateIndex ~= uint8(1)
            state.infoSnapshotUpdateIndex = uint8(idx);
        end
    end
    state.infoSnapshotSeq = uint16(mod(double(state.infoSnapshotSeq) + 1, 65536));
    state.infoSnapshotPayload = local_pack_info_snapshot(state);
end

function state = local_send_info_snapshot_if_due(state, opt, txSocket)
    if isempty(state.infoSnapshotPayload)
        state.infoSnapshotPayload = local_pack_info_snapshot(state);
    end
    if ~local_due(state.lastInfoSendTic, opt.InfoSendIntervalSec)
        return;
    end

    state.infoSnapshotPayload = local_pack_info_snapshot(state);
    local_send_udp_bytes(txSocket, opt.InfoRemoteHost, opt.InfoRemotePort, state.infoSnapshotPayload);
    state.lastInfoSendTic = tic;
    state.infoSendCount = state.infoSendCount + 1;
    % 更新索引表示“自上次发给relay以来至少成功解析过一次”。数据缓存和
    % fresh/valid保持不变；relay还会短暂锁存该事件，避免相位竞争或单包丢失。
    state.infoSnapshotUpdateIndex = uint8(0);
    if mod(state.infoSendCount, 10) == 1
        fprintf('[%s] info snapshot sent: seq=%d valid_mask=0x%02X fresh_mask=0x%02X payload=%s send_count=%d\n', ...
            local_clock_text(), double(state.infoSnapshotSeq), local_info_valid_mask(state), local_info_fresh_mask(state), ...
            local_bytes_to_hex(state.infoSnapshotPayload(1:min(12, numel(state.infoSnapshotPayload)))), ...
            state.infoSendCount);
    end
end

function payload = local_pack_info_snapshot(state)
    % v3 byte3低5位为valid_mask，高3位记录本快照由哪个命令更新。
    % 心跳会重复同一快照及seq，Python据此不会把重发误判成新命令。
    validAndUpdate = bitor(local_info_valid_mask(state), ...
        bitshift(bitand(uint8(state.infoSnapshotUpdateIndex), uint8(7)), 5));
    header = [uint8('I'); uint8('F'); uint8(3); ...
        validAndUpdate; local_info_fresh_mask(state)];
    seqBytes = typecast(uint16(state.infoSnapshotSeq), 'uint8');
    payload = uint8([header(:); seqBytes(:); state.infoCmdPayloads(:)]);
end

function mask = local_info_valid_mask(state)
    mask = uint8(0);
    for k = 1:min(5, numel(state.infoCmdValid))
        if state.infoCmdValid(k)
            mask = bitor(mask, bitshift(uint8(1), k - 1));
        end
    end
end

function mask = local_info_fresh_mask(state)
    mask = uint8(0);
    if ~isfield(state, 'infoCmdLastUpdateTic')
        return;
    end
    freshWindowSec = 3.0;
    if isfield(state, 'infoFreshWindowSec')
        freshWindowSec = state.infoFreshWindowSec;
    end
    for k = 1:min(5, numel(state.infoCmdLastUpdateTic))
        if ~isempty(state.infoCmdLastUpdateTic{k}) && ...
                toc(state.infoCmdLastUpdateTic{k}) <= freshWindowSec
            mask = bitor(mask, bitshift(uint8(1), k - 1));
        end
    end
end

function lengths = local_info_payload_lengths()
    lengths = [24 12 10 8 41];
end

function offsets = local_info_payload_offsets()
    lengths = local_info_payload_lengths();
    offsets = [1, 1 + cumsum(lengths(1:end-1))];
end

function totalLen = local_info_payload_total_length()
    totalLen = sum(local_info_payload_lengths());
end

function keyText = local_extract_jammer_key(result)
    keyText = "";
    if ~isfield(result, 'best') || ~isfield(result.best, 'frames') || isempty(result.best.frames)
        return;
    end

    frames = result.best.frames;
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
        return;
    end
end

function payload = local_pack_main_recv_key(keyText, prefixByte)
    keyBytes = uint8(char(string(keyText)));
    if numel(keyBytes) > 6
        keyBytes = keyBytes(1:6);
    elseif numel(keyBytes) < 6
        keyBytes = [keyBytes(:); zeros(6 - numel(keyBytes), 1, 'uint8')];
    else
        keyBytes = keyBytes(:);
    end

    payload = uint8([uint8(prefixByte); keyBytes(:)]);
end

function s = local_merge_info_state(s, update)
    fields = fieldnames(update);
    for k = 1:numel(fields)
        s.(fields{k}) = update.(fields{k});
    end
end

function state = local_record_error(state, err)
    state.lastError = string(err);
    state.errorCount = state.errorCount + 1;
end

function color = local_color_from_robot_id(robotId)
    if isempty(robotId) || isnan(robotId) || robotId <= 0
        color = "";
    elseif robotId >= 100
        color = "blue";
    else
        color = "red";
    end
end

function textOut = local_clock_text()
    textOut = string(datetime('now', 'Format', 'HH:mm:ss'));
end

function socket = local_create_udp_socket(localPort, timeoutSec)
    socket = javaObject('java.net.DatagramSocket', int32(localPort));
    socket.setSoTimeout(int32(max(1, round(timeoutSec * 1000))));
end

function [bytes, senderText, gotMessage] = local_receive_udp_bytes(socket, maxBytes)
    bytes = uint8([]);
    senderText = "";
    gotMessage = false;

    buffer = zeros(maxBytes, 1, 'int8');
    packet = javaObject('java.net.DatagramPacket', buffer, int32(numel(buffer)));

    try
        socket.receive(packet);
    catch
        return;
    end

    raw = packet.getData();
    L = packet.getLength();
    bytes = uint8(mod(double(raw(1:L)), 256));
    senderText = sprintf("%s:%d", char(packet.getAddress().getHostAddress()), packet.getPort());
    gotMessage = true;
end

function [bytes, senderText, gotMessage, drainCount] = local_receive_latest_udp_bytes(socket, maxBytes)
    [bytes, senderText, gotMessage] = local_receive_udp_bytes(socket, maxBytes);
    drainCount = 0;
    if ~gotMessage
        return;
    end

    drainCount = 1;
    maxDrainCount = 512;
    oldTimeoutMs = socket.getSoTimeout();
    socket.setSoTimeout(int32(1));
    cleanupObj = onCleanup(@() socket.setSoTimeout(oldTimeoutMs));

    while drainCount < maxDrainCount
        [nextBytes, nextSenderText, nextGotMessage] = local_receive_udp_bytes(socket, maxBytes);
        if ~nextGotMessage
            break;
        end
        bytes = nextBytes;
        senderText = nextSenderText;
        drainCount = drainCount + 1;
    end
end

function local_send_udp_bytes(socket, remoteHost, remotePort, bytes)
    address = javaMethod('getByName', 'java.net.InetAddress', char(string(remoteHost)));
    bytes = uint8(bytes(:));
    % Java 的 byte 是有符号 8 位，而 MATLAB 的 int8(uint8值)会执行饱和转换：
    % 0x80~0xFF 会全部变成 0x7F。这里必须按位重解释，保证协议中的每一位原样发送。
    javaBytes = typecast(bytes, 'int8');
    packet = javaObject('java.net.DatagramPacket', ...
        javaBytes, int32(numel(javaBytes)), address, int32(remotePort));
    socket.send(packet);
end

function hexText = local_bytes_to_hex(bytes)
    bytes = uint8(bytes(:));
    if isempty(bytes)
        hexText = "";
    else
        hexText = string(upper(reshape(dec2hex(bytes).', 1, [])));
    end
end

function local_close_udp_sockets(rxSocket, txSocket)
    try
        rxSocket.close();
    catch
    end
    try
        txSocket.close();
    catch
    end
end
