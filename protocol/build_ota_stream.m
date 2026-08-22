function otaSpec = build_ota_stream(payloadStreamBytes, accessCodeBytes)
    c = get_protocol_constants();
    payloadStreamBytes = uint8(payloadStreamBytes(:));
    accessCodeBytes = uint8(accessCodeBytes(:));
    payloadLengthBytes = c.otaPayloadLengthBytes;

    originalPayloadLengthBytes = numel(payloadStreamBytes);
    paddingLengthBytes = mod(-originalPayloadLengthBytes, payloadLengthBytes);
    if paddingLengthBytes > 0
        % 赛事引擎按连续数据流每 15 字节切片。有限测试缓存末尾不足一包时，
        % 只在整个缓存尾部补零；业务周期内部不补齐，避免把 140 字节
        % 信息波错误扩展成每周期 150 字节。
        payloadStreamBytes = [payloadStreamBytes; zeros(paddingLengthBytes, 1, 'uint8')];
    end

    numPackets = numel(payloadStreamBytes) / payloadLengthBytes;
    packets = repmat(struct( ...
        'packetIndex', uint16(0), ...
        'payloadBytes', uint8([]), ...
        'packetBytes', uint8([])), numPackets, 1);

    streamBytes = zeros(numPackets * c.otaPacketLengthBytes, 1, 'uint8');
    pWrite = 1;
    for k = 1:numPackets
        idx0 = (k-1)*payloadLengthBytes + 1;
        payloadBytes = payloadStreamBytes(idx0:idx0+payloadLengthBytes-1);
        packetBytes = build_ota_packet(payloadBytes, accessCodeBytes);

        packets(k).packetIndex = uint16(k);
        packets(k).payloadBytes = payloadBytes;
        packets(k).packetBytes = packetBytes;

        streamBytes(pWrite:pWrite+numel(packetBytes)-1) = packetBytes;
        pWrite = pWrite + numel(packetBytes);
    end

    otaSpec = struct( ...
        'payloadStreamBytes', payloadStreamBytes, ...
        'originalPayloadLengthBytes', originalPayloadLengthBytes, ...
        'paddingLengthBytes', paddingLengthBytes, ...
        'accessCodeBytes', accessCodeBytes, ...
        'packets', packets, ...
        'numPackets', numPackets, ...
        'packetLengthBytes', c.otaPacketLengthBytes, ...
        'streamBytes', streamBytes, ...
        'streamBits', bytes_to_bits_msb(streamBytes));
end
