function best = decode_gfsk_symbol_stream(symbolMetrics, reference)
    % 输入必须是新版过零同步器输出的一符号一点软判决流。
    % 本函数只处理比特边界和协议解析，不再搜索 47 个采样相位。
    useExpectedPayloadMatching = isfield(reference, 'useExpectedPayloadMatching') && ...
        reference.useExpectedPayloadMatching;
    best = struct();
    best.metric = -inf;
    best.bitShift = 0;
    best.bitMetric = [];
    best.bitsHat = [];
    best.bytesHat = [];
    best.otaPackets = [];
    best.payloadBytes = uint8([]);
    best.frames = [];
    best.validFrameCount = 0;
    best.matchedFrameCount = 0;
    best.validPacketCount = 0;
    best.totalBer = nan;
    best.totalBitErrors = 0;
    best.totalBitCount = 0;
    best.timingMetric = -inf;
    best.evaluatedCandidateCount = 0;
    best.accessCandidateCount = 0;
    best.accessAlignmentCount = 0;

    bitMetric = real(symbolMetrics(:));
    if numel(bitMetric) < 64
        return;
    end

    % 丢弃同步器起始瞬态；之后每个样本已经对应一个符号。
    bitMetric = bitMetric(5:end);
    timingMetric = mean(abs(bitMetric));
    bitsHatFull = bitMetric >= 0;
    accessBits = logical(bytes_to_bits_msb(reference.accessCodeBytes(:)).');

    accessStarts = strfind(logical(bitsHatFull(:).'), accessBits);
    if isempty(accessStarts)
        best.metric = 1e-3 * timingMetric;
        best.bitMetric = bitMetric;
        best.bitsHat = bitsHatFull(:);
        best.bytesHat = bits_to_bytes_msb(bitsHatFull);
        best.timingMetric = timingMetric;
        return;
    end

    candidateShifts = unique(mod(accessStarts - 1, 8), 'stable');
    % SymbolSynchronizer 在长窗口内可能因少量插入/删除而改变
    % bit-to-byte 对齐。旧实现只选一个全窗口 bitShift，会丢掉
    % 其他对齐位置上 access code 和 OTA 头都完全正确的包。
    % 现在从每个精确匹配的 access bit 位置独立严格组包；
    % 不容错 access code，不放宽 OTA 头或后续协议 CRC。
    otaPackets = local_extract_strict_ota_packets_from_bits( ...
        bitsHatFull, accessStarts, reference.accessCodeBytes);
    payloadBytes = local_collect_payload_bytes(otaPackets);
    frames = extract_valid_protocol_frames(payloadBytes);
    validFrameCount = numel(frames);
    validPacketCount = numel(otaPackets);
    metric = 250*validFrameCount + 10*validPacketCount + 1e-3*timingMetric;

    if useExpectedPayloadMatching
        [matchedFrameCount, totalErr, totalCnt] = ...
            local_match_frames(frames, reference.protocolFrames);
        metric = metric + 5000*matchedFrameCount;
        if totalCnt > 0
            totalBer = totalErr / totalCnt;
            metric = metric - 50*totalBer;
        else
            totalBer = nan;
        end
    else
        matchedFrameCount = 0;
        totalErr = 0;
        totalCnt = 0;
        totalBer = nan;
    end

    best.metric = metric;
    best.bitShift = candidateShifts(1);
    best.bitMetric = bitMetric;
    best.bitsHat = bitsHatFull(:);
    best.bytesHat = bits_to_bytes_msb(bitsHatFull);
    best.otaPackets = otaPackets;
    best.payloadBytes = payloadBytes(:);
    best.frames = frames;
    best.validFrameCount = validFrameCount;
    best.matchedFrameCount = matchedFrameCount;
    best.validPacketCount = validPacketCount;
    best.totalBitErrors = totalErr;
    best.totalBitCount = totalCnt;
    best.totalBer = totalBer;
    best.timingMetric = timingMetric;
    best.accessCandidateCount = numel(accessStarts);
    best.accessAlignmentCount = numel(candidateShifts);
    best.evaluatedCandidateCount = numel(accessStarts);
end

function packets = local_extract_strict_ota_packets_from_bits( ...
        bitStream, accessStarts, accessCodeBytes)
    c = get_protocol_constants();
    packetBitCount = c.otaPacketLengthBytes * 8;
    packets = struct('startIndex', {}, 'startBitIndex', {}, ...
        'packetBytes', {}, 'payloadBytes', {}, 'result', {});
    lastAcceptedEnd = 0;
    for startIndex = accessStarts
        if startIndex <= lastAcceptedEnd || ...
                startIndex + packetBitCount - 1 > numel(bitStream)
            continue;
        end
        packetBits = bitStream(startIndex:startIndex + packetBitCount - 1);
        packetBytes = bits_to_bytes_msb(packetBits);
        parsed = parse_ota_packet(packetBytes, accessCodeBytes);
        if ~parsed.ok
            continue;
        end
        item = struct( ...
            'startIndex', startIndex, ...
            'startBitIndex', startIndex, ...
            'packetBytes', uint8(packetBytes(:)), ...
            'payloadBytes', uint8(parsed.payloadBytes(:)), ...
            'result', parsed);
        packets(end+1) = item; %#ok<AGROW>
        lastAcceptedEnd = startIndex + packetBitCount - 1;
    end
end

function payloadBytes = local_collect_payload_bytes(otaPackets)
    if isempty(otaPackets)
        payloadBytes = uint8([]);
        return;
    end
    payloadBytes = vertcat(otaPackets.payloadBytes);
    payloadBytes = uint8(payloadBytes(:));
end

function [matchedFrameCount, totalErr, totalCnt] = local_match_frames(frames, expectedFrames)
    matchedFrameCount = 0;
    totalErr = 0;
    totalCnt = 0;
    for k = 1:numel(frames)
        fr = frames(k).result;
        [isMatch, ~, matchedInfo] = ...
            protocol_payload_matches_expected(fr, expectedFrames);
        if ~isMatch
            continue;
        end
        matchedFrameCount = matchedFrameCount + 1;
        gotBits = bytes_to_bits_msb(frames(k).frameBytes(:));
        expBits = bytes_to_bits_msb(matchedInfo.frameBytes(:));
        L = min(numel(gotBits), numel(expBits));
        totalErr = totalErr + sum(gotBits(1:L) ~= expBits(1:L));
        totalCnt = totalCnt + L;
    end
end
