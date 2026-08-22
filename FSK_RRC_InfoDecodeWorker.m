function FSK_RRC_InfoDecodeWorker(queueDir, resultHost, resultPort, parentPid, workerIndex)
    % 长驻信息波解码子进程：从 /dev/shm 领取 IQ 窗口并回传小体积结果。
    project_setup();
    queueDir = string(queueDir);
    resultHost = string(resultHost);
    resultPort = double(resultPort);
    parentPid = double(parentPid);
    workerIndex = double(workerIndex);
    configData = load(fullfile(queueDir, 'worker_config.mat'), 'workerConfig');
    workerConfig = configData.workerConfig;
    txSocket = javaObject('java.net.DatagramSocket');
    cleanupObj = onCleanup(@() txSocket.close());
    fprintf('[%s] info decode worker ready: index=%d pid=%d parent=%d queue=%s\n', ...
        local_clock_text(), workerIndex, feature('getpid'), parentPid, queueDir);

    lastParentCheckTic = tic;
    while true
        if isfile(fullfile(queueDir, "STOP"))
            break;
        end
        if toc(lastParentCheckTic) >= 1.0
            lastParentCheckTic = tic;
            [parentStatus, ~] = system(sprintf('kill -0 %d >/dev/null 2>&1', round(parentPid)));
            if parentStatus ~= 0
                fprintf('[%s] parent process disappeared, worker exits.\n', local_clock_text());
                break;
            end
        end

        % 每个 worker 先领取自己的合成预热窗口，之后再共同竞争正式窗口。
        readyFiles = dir(fullfile(queueDir, sprintf( ...
            'warmup_%03d_window_*.ready', round(workerIndex))));
        if isempty(readyFiles)
            readyFiles = dir(fullfile(queueDir, 'window_*.ready'));
        end
        if isempty(readyFiles)
            pause(0.005);
            continue;
        end
        [~, order] = sort({readyFiles.name});
        claimed = false;
        for fileIdx = order
            readyPath = fullfile(queueDir, readyFiles(fileIdx).name);
            claimedPath = readyPath + sprintf('.work_%d', round(feature('getpid')));
            [claimOk, ~] = movefile(readyPath, claimedPath);
            if ~claimOk
                continue;
            end
            claimed = true;
            local_process_one_window( ...
                claimedPath, readyFiles(fileIdx).name, workerConfig, ...
                txSocket, resultHost, resultPort);
            break;
        end
        if ~claimed
            pause(0.002);
        end
    end
    fprintf('[%s] info decode worker stopped: index=%d\n', ...
        local_clock_text(), workerIndex);
end

function local_process_one_window( ...
        claimedPath, originalName, workerConfig, txSocket, resultHost, resultPort)
    fileCleanup = onCleanup(@() local_delete_file(claimedPath));
    tokens = regexp(originalName, ...
        '^(?:warmup_\d+_)?window_(\d+)_(\d+)_(\d+)\.ready$', ...
        'tokens', 'once');
    if isempty(tokens)
        return;
    end
    sequence = str2double(tokens{1});
    windowStartSample = str2double(tokens{2});
    windowEndSample = str2double(tokens{3});
    try
        samples = local_read_iq_file(claimedPath);
        decoded = FSK_RRC_DecodeInfoWindow( ...
            samples, workerConfig.captureSampleRateHz, ...
            workerConfig.sourceName, workerConfig.decodeArgs);
    catch ME
        decoded = struct( ...
            'ok', false, ...
            'errorText', string(getReport(ME, 'extended', 'hyperlinks', 'off')), ...
            'updates', struct( ...
                'cmdId', {}, 'index', {}, 'seq', {}, ...
                'dataBytes', {}, 'type', {}), ...
            'validFrameCount', 0, ...
            'validPacketCount', 0, ...
            'evaluatedCandidateCount', 0, ...
            'metric', -inf, ...
            'decodeElapsedSec', 0);
    end
    payload = local_pack_result( ...
        sequence, windowStartSample, windowEndSample, decoded);
    local_send_udp_bytes(txSocket, resultHost, resultPort, payload);
end

function samples = local_read_iq_file(pathText)
    fileId = fopen(pathText, 'rb');
    if fileId < 0
        error('无法读取 IQ 队列文件：%s', pathText);
    end
    cleanupObj = onCleanup(@() fclose(fileId));
    interleaved = fread(fileId, [2, inf], '*single');
    if size(interleaved, 1) ~= 2
        error('IQ 队列文件格式错误：%s', pathText);
    end
    samples = complex(double(interleaved(1, :)), double(interleaved(2, :))).';
end

function payload = local_pack_result(sequence, windowStartSample, windowEndSample, decoded)
    errorBytes = unicode2native(char(string(decoded.errorText)), 'UTF-8');
    errorBytes = uint8(errorBytes(1:min(numel(errorBytes), 2000)));
    updates = decoded.updates;
    if numel(updates) > 255
        updates = updates(1:255);
    end
    payload = uint8(['I'; 'W'; 2]);
    payload = [payload; local_scalar_bytes(uint64(sequence))]; %#ok<AGROW>
    payload = [payload; local_scalar_bytes(uint64(windowStartSample))]; %#ok<AGROW>
    payload = [payload; local_scalar_bytes(uint64(windowEndSample))]; %#ok<AGROW>
    payload = [payload; local_scalar_bytes(double(decoded.decodeElapsedSec))]; %#ok<AGROW>
    payload = [payload; local_scalar_bytes(uint16(decoded.validFrameCount))]; %#ok<AGROW>
    payload = [payload; local_scalar_bytes(uint16(decoded.validPacketCount))]; %#ok<AGROW>
    payload = [payload; local_scalar_bytes(uint16(decoded.evaluatedCandidateCount))]; %#ok<AGROW>
    payload = [payload; local_scalar_bytes(double(decoded.metric))]; %#ok<AGROW>
    payload = [payload; uint8(logical(decoded.ok)); uint8(numel(updates))]; %#ok<AGROW>
    payload = [payload; local_scalar_bytes(uint16(numel(errorBytes))); errorBytes(:)]; %#ok<AGROW>
    for updateIdx = 1:numel(updates)
        dataBytes = uint8(updates(updateIdx).dataBytes(:));
        payload = [payload; ... %#ok<AGROW>
            local_scalar_bytes(uint16(updates(updateIdx).cmdId)); ...
            uint8(updates(updateIdx).seq); ...
            local_scalar_bytes(uint16(numel(dataBytes))); ...
            dataBytes];
    end
end

function bytes = local_scalar_bytes(value)
    bytes = typecast(value, 'uint8').';
    bytes = uint8(bytes(:));
end

function local_send_udp_bytes(socket, remoteHost, remotePort, bytes)
    address = javaMethod('getByName', 'java.net.InetAddress', char(remoteHost));
    javaBytes = typecast(uint8(bytes(:)), 'int8');
    packet = javaObject('java.net.DatagramPacket', ...
        javaBytes, int32(numel(javaBytes)), address, int32(remotePort));
    socket.send(packet);
end

function local_delete_file(pathText)
    try
        delete(pathText);
    catch
    end
end

function textOut = local_clock_text()
    textOut = string(datetime('now', 'Format', 'HH:mm:ss'));
end
