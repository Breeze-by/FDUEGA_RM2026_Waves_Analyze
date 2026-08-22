classdef InfoWaveContinuousReceiver < handle
    % 信息波持续采集生产者与多进程解码消费者。
    %
    % 主 MATLAB 进程只持有 Pluto 并连续调用 rx()。重叠 IQ 窗口以 single
    % 复数交错格式写入 /dev/shm 有界队列，多个长驻 MATLAB 子进程竞争领取
    % 并执行原正式解调器。小体积解码结果通过本机 UDP 返回主进程。

    properties (SetAccess = private)
        sourceName string
        radioID string
        captureSampleRateHz double
        samplesPerFrame double
        windowSec double
        strideSec double
        maxPendingWindows double
        workerCount double
        rx
        receiverReused logical = false
        running logical = false
        totalCapturedSamples double = 0
        capturedFrameCount double = 0
        submittedWindowCount double = 0
        completedWindowCount double = 0
        failedWindowCount double = 0
        saturatedStepCount double = 0
        overflowCount double = 0
        maxPendingObserved double = 0
        maxSubmitGapSamples double = 0
        lastSubmitEndSample double = 0
        lastCaptureEpochSec double = 0
        queueDir string = ""
        workerPids double = []
        workerWarmupSubmittedCount double = 0
        workerWarmupCompletedCount double = 0
    end

    properties (Access = private)
        ringBuffer
        ringCapacitySamples double
        ringWriteIndex double = 1
        windowSamples double
        strideSamples double
        decodeArgs cell
        resultSocket
        resultPort double
        nextWindowSequence double = 1
        pending struct
        streamStartTic
    end

    methods
        function obj = InfoWaveContinuousReceiver(action, opt)
            obj.sourceName = string(action.sourceName);
            obj.radioID = string(action.rxRadioID);
            if isfield(opt, 'InfoCaptureSampleRateHz')
                obj.captureSampleRateHz = double(opt.InfoCaptureSampleRateHz);
            else
                obj.captureSampleRateHz = double(opt.CaptureSampleRateHz);
            end
            obj.samplesPerFrame = double(opt.SamplesPerFrame);
            obj.windowSec = max(0.05, double(opt.InfoStreamDecodeWindowSec));
            obj.strideSec = max( ...
                obj.samplesPerFrame / obj.captureSampleRateHz, ...
                double(opt.InfoStreamDecodeStrideSec));
            obj.maxPendingWindows = max(1, round(double(opt.InfoStreamMaxPendingWindows)));
            obj.workerCount = max(1, round(double(opt.InfoStreamWorkerCount)));
            obj.windowSamples = max(obj.samplesPerFrame, ...
                round(obj.windowSec * obj.captureSampleRateHz));
            obj.strideSamples = max(obj.samplesPerFrame, ...
                round(obj.strideSec * obj.captureSampleRateHz));
            obj.ringCapacitySamples = max( ...
                obj.windowSamples + 2 * obj.samplesPerFrame, ...
                round(double(opt.InfoStreamRingBufferSec) * obj.captureSampleRateHz));
            obj.ringBuffer = complex(zeros(obj.ringCapacitySamples, 1));
            obj.decodeArgs = local_build_decode_args(opt);
            obj.pending = local_empty_pending();
            obj.start_workers();
            % worker 使用纯零合成窗口预热解调器内部 MEX/System Object。
            % 不提交赛前真实 IQ，因此不突破 game_progress==4 的业务解析门控。
            obj.submit_worker_warmups();
            obj.start_receiver(opt);
        end

        function [records, heartbeatDue, capturedFrame] = step(obj, submitDecode)
            if ~obj.running
                error('信息波持续接收器尚未启动。');
            end
            if nargin < 2
                submitDecode = true;
            end
            records = obj.collect_finished();
            heartbeatDue = false;
            capturedFrame = complex(zeros(0, 1));

            [frame, validFrame, overflow] = obj.rx();
            if logical(overflow)
                obj.overflowCount = obj.overflowCount + 1;
            end
            if ~logical(validFrame) || isempty(frame)
                return;
            end
            % 第三个返回值仅供独立 Web 诊断显示原始 IQ；正式调用只接收
            % 前两个返回值，持续采集与解码行为不变。
            capturedFrame = frame(:);
            obj.append_samples(frame);
            obj.capturedFrameCount = obj.capturedFrameCount + 1;
            obj.totalCapturedSamples = obj.totalCapturedSamples + numel(frame);
            obj.lastCaptureEpochSec = posixtime(datetime('now', 'TimeZone', 'UTC'));
            heartbeatDue = true;

            moreRecords = obj.collect_finished();
            records = [records; moreRecords];
            if submitDecode
                obj.submit_window_if_due();
            end
        end

        function reset_epoch(obj)
            % 比赛开始时只重置采样纪元，保留已预热的 Pluto 与解码进程。
            % 已被 worker 领取的旧窗口可能稍后返回，但 pending 已清空，因此
            % collect_finished() 会按序号丢弃它们，不会污染新小局缓存。
            if ~obj.running
                return;
            end
            obj.collect_finished();
            obj.pending = local_empty_pending();
            local_delete_queued_windows(obj.queueDir);
            obj.ringBuffer(:) = 0;
            obj.ringWriteIndex = 1;
            obj.totalCapturedSamples = 0;
            obj.capturedFrameCount = 0;
            obj.submittedWindowCount = 0;
            obj.completedWindowCount = 0;
            obj.failedWindowCount = 0;
            obj.saturatedStepCount = 0;
            obj.overflowCount = 0;
            obj.maxPendingObserved = 0;
            obj.maxSubmitGapSamples = 0;
            obj.lastSubmitEndSample = 0;
            obj.lastCaptureEpochSec = 0;
            obj.streamStartTic = tic;
            fprintf(['[%s] info continuous receiver epoch reset: source=%s ' ...
                'radio=%s worker_warmups=%d/%d\n'], ...
                local_clock_text(), obj.sourceName, obj.radioID, ...
                obj.workerWarmupCompletedCount, obj.workerWarmupSubmittedCount);
        end

        function records = collect_finished(obj)
            records = local_empty_records();
            if isempty(obj.resultSocket)
                return;
            end
            for packetIdx = 1:128
                [payload, gotPacket] = local_receive_udp_nowait(obj.resultSocket, 8192);
                if ~gotPacket
                    break;
                end
                try
                    decodedPacket = local_unpack_worker_result(payload);
                catch ME
                    fprintf('[%s] info worker result ignored: %s\n', ...
                        local_clock_text(), ME.message);
                    continue;
                end
                pendingIdx = find([obj.pending.sequence] == decodedPacket.sequence, 1);
                if isempty(pendingIdx)
                    continue;
                end
                item = obj.pending(pendingIdx);
                obj.pending(pendingIdx) = [];
                if item.isWarmup
                    obj.workerWarmupCompletedCount = ...
                        obj.workerWarmupCompletedCount + 1;
                    if ~decodedPacket.decoded.ok
                        fprintf('[%s] info worker synthetic warmup failed: %s\n', ...
                            local_clock_text(), decodedPacket.decoded.errorText);
                    end
                    continue;
                end
                record = struct( ...
                    'windowStartSample', item.windowStartSample, ...
                    'windowEndSample', item.windowEndSample, ...
                    'submitEpochSec', item.submitEpochSec, ...
                    'completeEpochSec', posixtime(datetime('now', 'TimeZone', 'UTC')), ...
                    'queueElapsedSec', toc(item.submitTic), ...
                    'decoded', decodedPacket.decoded);
                if decodedPacket.decoded.ok
                    obj.completedWindowCount = obj.completedWindowCount + 1;
                else
                    obj.failedWindowCount = obj.failedWindowCount + 1;
                end
                records(end+1, 1) = record; %#ok<AGROW>
            end
        end

        function stats = get_stats(obj)
            stats = struct( ...
                'running', obj.running, ...
                'sourceName', obj.sourceName, ...
                'radioID', obj.radioID, ...
                'totalCapturedSamples', obj.totalCapturedSamples, ...
                'capturedFrameCount', obj.capturedFrameCount, ...
                'submittedWindowCount', obj.submittedWindowCount, ...
                'completedWindowCount', obj.completedWindowCount, ...
                'failedWindowCount', obj.failedWindowCount, ...
                'pendingWindowCount', numel(obj.pending), ...
                'saturatedStepCount', obj.saturatedStepCount, ...
                'maxPendingObserved', obj.maxPendingObserved, ...
                'maxSubmitGapSec', obj.maxSubmitGapSamples / obj.captureSampleRateHz, ...
                'overflowCount', obj.overflowCount, ...
                'workerCount', obj.workerCount, ...
                'workerPids', obj.workerPids, ...
                'workerWarmupSubmittedCount', obj.workerWarmupSubmittedCount, ...
                'workerWarmupCompletedCount', obj.workerWarmupCompletedCount, ...
                'queueDir', obj.queueDir, ...
                'elapsedSec', toc(obj.streamStartTic));
        end

        function stop(obj)
            if ~obj.running && isempty(obj.workerPids)
                return;
            end
            obj.running = false;
            obj.rx = [];
            local_touch_file(fullfile(obj.queueDir, "STOP"));
            pause(0.2);
            for pidIdx = 1:numel(obj.workerPids)
                workerPid = round(obj.workerPids(pidIdx));
                if workerPid > 1
                    system(sprintf('kill -TERM %d >/dev/null 2>&1', workerPid));
                end
            end
            obj.workerPids = [];
            if ~isempty(obj.resultSocket)
                try
                    obj.resultSocket.close();
                catch
                end
                obj.resultSocket = [];
            end
            obj.pending = local_empty_pending();
            pause(0.05);
            if strlength(obj.queueDir) > 0 && isfolder(obj.queueDir)
                try
                    rmdir(obj.queueDir, 's');
                catch
                end
            end
        end

        function delete(obj)
            obj.stop();
        end
    end

    methods (Access = private)
        function start_workers(obj)
            obj.resultSocket = javaObject('java.net.DatagramSocket', int32(0));
            obj.resultSocket.setSoTimeout(int32(1));
            obj.resultPort = double(obj.resultSocket.getLocalPort());

            parentPid = feature('getpid');
            uniqueStamp = round(posixtime(datetime('now', 'TimeZone', 'UTC')) * 1e6);
            obj.queueDir = string(fullfile('/dev/shm', ...
                sprintf('rm_info_stream_%d_%d', parentPid, uniqueStamp)));
            mkdir(obj.queueDir);
            workerConfig = struct( ...
                'sourceName', obj.sourceName, ...
                'captureSampleRateHz', obj.captureSampleRateHz, ...
                'decodeArgs', {obj.decodeArgs});
            save(fullfile(obj.queueDir, 'worker_config.mat'), 'workerConfig', '-v7');

            waveDir = string(fileparts(mfilename('fullpath')));
            obj.workerPids = zeros(1, obj.workerCount);
            for workerIdx = 1:obj.workerCount
                workerLog = fullfile(obj.queueDir, sprintf('worker_%d.log', workerIdx));
                matlabCode = sprintf( ...
                    ['cd(''%s''); FSK_RRC_InfoDecodeWorker(''%s'', ' ...
                     '''127.0.0.1'', %d, %d, %d);'], ...
                    local_escape_matlab_text(waveDir), ...
                    local_escape_matlab_text(obj.queueDir), ...
                    round(obj.resultPort), round(parentPid), workerIdx);
                command = sprintf( ...
                    'matlab -batch "%s" > "%s" 2>&1 & echo $!', ...
                    strrep(matlabCode, '"', '\"'), workerLog);
                [status, output] = system(command);
                workerPid = str2double(strtrim(output));
                if status ~= 0 || ~isfinite(workerPid) || workerPid <= 1
                    error('信息波解码 worker %d 启动失败：%s', workerIdx, output);
                end
                obj.workerPids(workerIdx) = workerPid;
            end
            fprintf('[%s] info decode workers started: count=%d pids=%s queue=%s result_port=%d\n', ...
                local_clock_text(), obj.workerCount, mat2str(obj.workerPids), ...
                obj.queueDir, obj.resultPort);
        end

        function start_receiver(obj, opt)
            sourceCfg = get_gfsk_source_config(obj.sourceName);
            rfBandwidthHz = opt.RxRFBandwidthHz;
            if isempty(rfBandwidthHz)
                rfBandwidthHz = sourceCfg.rxBandwidth;
            end
            radioCtx = resolve_pluto_radio_id(obj.radioID, "rx");
            reusableCfg = struct( ...
                'radioID', string(radioCtx.resolvedRadioID), ...
                'centerFrequency', double(sourceCfg.fc + opt.InfoCenterFrequencyOffsetHz), ...
                'sampleRate', obj.captureSampleRateHz, ...
                'samplesPerFrame', obj.samplesPerFrame, ...
                'useAGC', logical(opt.UseAGC), ...
                'agcMode', opt.AGCMode, ...
                'gainDB', double(opt.RxGain_dB), ...
                'rfBandwidthHz', double(rfBandwidthHz));
            [obj.rx, obj.receiverReused] = reusable_pluto_rx("acquire", reusableCfg);
            if ~obj.receiverReused
                info(obj.rx);
                for warmupIdx = 1:double(opt.WarmupFrames)
                    obj.rx();
                end
                apply_pluto_rx_rf_bandwidth(obj.rx, radioCtx.resolvedRadioID, rfBandwidthHz);
            end
            obj.streamStartTic = tic;
            obj.running = true;
            fprintf(['[%s] info continuous receiver started: source=%s radio=%s ' ...
                'frame_samples=%d window=%.3f s stride=%.3f s ring=%.3f s ' ...
                'max_pending=%d workers=%d reused=%d worker_warmups=%d/%d\n'], ...
                local_clock_text(), obj.sourceName, obj.radioID, obj.samplesPerFrame, ...
                obj.windowSec, obj.strideSec, ...
                obj.ringCapacitySamples / obj.captureSampleRateHz, ...
                obj.maxPendingWindows, obj.workerCount, obj.receiverReused, ...
                obj.workerWarmupCompletedCount, obj.workerWarmupSubmittedCount);
        end

        function submit_worker_warmups(obj)
            % 为每个 worker 准备一个定向任务，确保所有消费者都在 Pluto
            % 正式采集前完成一次冷启动；这些任务不计入比赛窗口统计。
            syntheticWindow = complex(zeros(obj.windowSamples, 1, 'single'));
            warmupCount = obj.workerCount;
            for warmupIdx = 1:warmupCount
                sequence = obj.nextWindowSequence;
                obj.nextWindowSequence = obj.nextWindowSequence + 1;
                readyPath = fullfile(obj.queueDir, sprintf( ...
                    'warmup_%03d_window_%012d_%020d_%020d.ready', ...
                    warmupIdx, sequence, 0, 0));
                tempPath = readyPath + ".tmp";
                local_write_iq_file(tempPath, syntheticWindow);
                [moveOk, moveMessage] = movefile(tempPath, readyPath, 'f');
                if ~moveOk
                    error('提交信息波 worker 预热窗口失败：%s', moveMessage);
                end
                item = struct( ...
                    'sequence', sequence, ...
                    'windowStartSample', 0, ...
                    'windowEndSample', 0, ...
                    'submitEpochSec', posixtime(datetime('now', 'TimeZone', 'UTC')), ...
                    'submitTic', tic, ...
                    'isWarmup', true);
                obj.pending(end+1) = item;
                obj.workerWarmupSubmittedCount = ...
                    obj.workerWarmupSubmittedCount + 1;
            end
        end

        function append_samples(obj, samples)
            samples = samples(:);
            sampleCount = numel(samples);
            if sampleCount >= obj.ringCapacitySamples
                samples = samples(end-obj.ringCapacitySamples+1:end);
                sampleCount = numel(samples);
            end
            firstCount = min(sampleCount, obj.ringCapacitySamples - obj.ringWriteIndex + 1);
            obj.ringBuffer(obj.ringWriteIndex:obj.ringWriteIndex + firstCount - 1) = ...
                samples(1:firstCount);
            remaining = sampleCount - firstCount;
            if remaining > 0
                obj.ringBuffer(1:remaining) = samples(firstCount+1:end);
            end
            obj.ringWriteIndex = mod(obj.ringWriteIndex - 1 + sampleCount, ...
                obj.ringCapacitySamples) + 1;
        end

        function submit_window_if_due(obj)
            if obj.totalCapturedSamples < obj.windowSamples
                return;
            end
            if obj.lastSubmitEndSample > 0 && ...
                    obj.totalCapturedSamples - obj.lastSubmitEndSample < obj.strideSamples
                return;
            end
            if numel(obj.pending) >= obj.maxPendingWindows
                obj.saturatedStepCount = obj.saturatedStepCount + 1;
                return;
            end

            window = obj.latest_window();
            windowEndSample = obj.totalCapturedSamples;
            windowStartSample = windowEndSample - obj.windowSamples + 1;
            if obj.lastSubmitEndSample > 0
                obj.maxSubmitGapSamples = max( ...
                    obj.maxSubmitGapSamples, windowEndSample - obj.lastSubmitEndSample);
            end
            sequence = obj.nextWindowSequence;
            obj.nextWindowSequence = obj.nextWindowSequence + 1;
            readyPath = fullfile(obj.queueDir, sprintf( ...
                'window_%012d_%020d_%020d.ready', ...
                sequence, windowStartSample, windowEndSample));
            tempPath = readyPath + ".tmp";
            local_write_iq_file(tempPath, window);
            [moveOk, moveMessage] = movefile(tempPath, readyPath, 'f');
            if ~moveOk
                error('提交信息波解码窗口失败：%s', moveMessage);
            end

            item = struct( ...
                'sequence', sequence, ...
                'windowStartSample', windowStartSample, ...
                'windowEndSample', windowEndSample, ...
                'submitEpochSec', posixtime(datetime('now', 'TimeZone', 'UTC')), ...
                'submitTic', tic, ...
                'isWarmup', false);
            obj.pending(end+1) = item;
            obj.submittedWindowCount = obj.submittedWindowCount + 1;
            obj.maxPendingObserved = max(obj.maxPendingObserved, numel(obj.pending));
            obj.lastSubmitEndSample = windowEndSample;
        end

        function window = latest_window(obj)
            endIndex = obj.ringWriteIndex - 1;
            if endIndex < 1
                endIndex = obj.ringCapacitySamples;
            end
            startIndex = endIndex - obj.windowSamples + 1;
            if startIndex >= 1
                window = obj.ringBuffer(startIndex:endIndex);
            else
                window = [ ...
                    obj.ringBuffer(obj.ringCapacitySamples + startIndex:end); ...
                    obj.ringBuffer(1:endIndex)];
            end
        end
    end
end

function decodeArgs = local_build_decode_args(opt)
    decodeArgs = { ...
        'RxCenterFrequencyOffsetHz', opt.InfoCenterFrequencyOffsetHz, ...
        'RxRFBandwidthHz', opt.RxRFBandwidthHz, ...
        'PreDemodChannelCutoffHz', opt.InfoPreDemodChannelCutoffHz, ...
        'PreDemodChannelFilterOrder', opt.InfoPreDemodChannelFilterOrder, ...
        'QuadratureDemodGain', opt.InfoQuadratureDemodGain, ...
        'SymbolSyncLoopBandwidth', opt.InfoSymbolSyncLoopBandwidth, ...
        'SymbolSyncDampingFactor', opt.InfoSymbolSyncDampingFactor, ...
        'SymbolSyncDetectorGain', opt.InfoSymbolSyncDetectorGain};
end

function local_write_iq_file(pathText, samples)
    fileId = fopen(pathText, 'wb');
    if fileId < 0
        error('无法创建 IQ 队列文件：%s', pathText);
    end
    cleanupObj = onCleanup(@() fclose(fileId));
    interleaved = zeros(2, numel(samples), 'single');
    interleaved(1, :) = single(real(samples));
    interleaved(2, :) = single(imag(samples));
    written = fwrite(fileId, interleaved, 'single');
    if written ~= 2 * numel(samples)
        error('IQ 队列文件写入不完整：expected=%d actual=%d', ...
            2 * numel(samples), written);
    end
end

function [payload, gotPacket] = local_receive_udp_nowait(socket, maxBytes)
    payload = uint8([]);
    gotPacket = false;
    buffer = zeros(maxBytes, 1, 'int8');
    packet = javaObject('java.net.DatagramPacket', buffer, int32(numel(buffer)));
    try
        socket.receive(packet);
    catch
        return;
    end
    raw = packet.getData();
    payload = uint8(mod(double(raw(1:packet.getLength())), 256));
    gotPacket = true;
end

function packet = local_unpack_worker_result(payload)
    payload = uint8(payload(:));
    if numel(payload) < 53 || ~isequal(payload(1:3), uint8(['I'; 'W'; 2]))
        error('worker 结果包头或长度无效。');
    end
    cursor = 4;
    [sequence, cursor] = local_read_scalar(payload, cursor, 'uint64');
    [~, cursor] = local_read_scalar(payload, cursor, 'uint64');
    [~, cursor] = local_read_scalar(payload, cursor, 'uint64');
    [decodeElapsedSec, cursor] = local_read_scalar(payload, cursor, 'double');
    [validFrameCount, cursor] = local_read_scalar(payload, cursor, 'uint16');
    [validPacketCount, cursor] = local_read_scalar(payload, cursor, 'uint16');
    [evaluatedCandidateCount, cursor] = local_read_scalar(payload, cursor, 'uint16');
    [metric, cursor] = local_read_scalar(payload, cursor, 'double');
    ok = payload(cursor) ~= 0;
    cursor = cursor + 1;
    updateCount = double(payload(cursor));
    cursor = cursor + 1;
    [errorLength, cursor] = local_read_scalar(payload, cursor, 'uint16');
    errorLength = double(errorLength);
    if cursor + errorLength - 1 > numel(payload)
        error('worker 错误文本长度越界。');
    end
    errorText = string(native2unicode(payload(cursor:cursor+errorLength-1).', 'UTF-8'));
    cursor = cursor + errorLength;

    updates = struct( ...
        'cmdId', {}, 'index', {}, 'seq', {}, 'dataBytes', {}, 'type', {});
    cmdIds = uint16([hex2dec('0A01'), hex2dec('0A02'), hex2dec('0A03'), ...
        hex2dec('0A04'), hex2dec('0A05')]);
    typeNames = ["broadcast_positions", "broadcast_hp", ...
        "broadcast_projectiles", "broadcast_economy", "broadcast_buffs"];
    for updateIdx = 1:updateCount
        [cmdId, cursor] = local_read_scalar(payload, cursor, 'uint16');
        if cursor > numel(payload)
            error('worker 命令 seq 字段越界。');
        end
        frameSeq = payload(cursor);
        cursor = cursor + 1;
        [dataLength, cursor] = local_read_scalar(payload, cursor, 'uint16');
        dataLength = double(dataLength);
        if cursor + dataLength - 1 > numel(payload)
            error('worker 命令 payload 长度越界。');
        end
        cmdIndex = find(uint16(cmdId) == cmdIds, 1);
        if ~isempty(cmdIndex)
            updates(end+1) = struct( ...
                'cmdId', uint16(cmdId), ...
                'index', double(cmdIndex), ...
                'seq', uint8(frameSeq), ...
                'dataBytes', uint8(payload(cursor:cursor+dataLength-1)), ...
                'type', typeNames(cmdIndex)); %#ok<AGROW>
        end
        cursor = cursor + dataLength;
    end
    decoded = struct( ...
        'ok', logical(ok), ...
        'errorText', errorText, ...
        'updates', updates, ...
        'validFrameCount', double(validFrameCount), ...
        'validPacketCount', double(validPacketCount), ...
        'evaluatedCandidateCount', double(evaluatedCandidateCount), ...
        'metric', double(metric), ...
        'decodeElapsedSec', double(decodeElapsedSec));
    packet = struct('sequence', double(sequence), 'decoded', decoded);
end

function [value, nextCursor] = local_read_scalar(payload, cursor, typeName)
    byteCount = numel(typecast(cast(0, typeName), 'uint8'));
    if cursor + byteCount - 1 > numel(payload)
        error('worker 结果包字段越界：%s。', typeName);
    end
    value = typecast(uint8(payload(cursor:cursor+byteCount-1)), typeName);
    nextCursor = cursor + byteCount;
end

function pending = local_empty_pending()
    pending = struct( ...
        'sequence', {}, ...
        'windowStartSample', {}, ...
        'windowEndSample', {}, ...
        'submitEpochSec', {}, ...
        'submitTic', {}, ...
        'isWarmup', {});
end

function records = local_empty_records()
    records = struct( ...
        'windowStartSample', {}, ...
        'windowEndSample', {}, ...
        'submitEpochSec', {}, ...
        'completeEpochSec', {}, ...
        'queueElapsedSec', {}, ...
        'decoded', {});
end

function local_touch_file(pathText)
    if strlength(string(pathText)) == 0
        return;
    end
    fileId = fopen(pathText, 'wb');
    if fileId >= 0
        fclose(fileId);
    end
end

function local_delete_queued_windows(queueDir)
    if strlength(string(queueDir)) == 0 || ~isfolder(queueDir)
        return;
    end
    patterns = [ ...
        "window_*.ready", "window_*.tmp", ...
        "warmup_*_window_*.ready", "warmup_*_window_*.tmp"];
    for patternIdx = 1:numel(patterns)
        entries = dir(fullfile(queueDir, patterns(patternIdx)));
        for entryIdx = 1:numel(entries)
            try
                delete(fullfile(entries(entryIdx).folder, entries(entryIdx).name));
            catch
            end
        end
    end
end

function escaped = local_escape_matlab_text(value)
    escaped = strrep(char(string(value)), '''', '''''');
end

function textOut = local_clock_text()
    textOut = string(datetime('now', 'Format', 'HH:mm:ss'));
end
