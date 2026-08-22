function packets = extract_valid_ota_packets(byteStream, accessCodeBytes)
    c = get_protocol_constants();
    byteStream = uint8(byteStream(:));
    accessCodeBytes = uint8(accessCodeBytes(:));
    packets = struct('startIndex', {}, 'packetBytes', {}, 'payloadBytes', {}, 'result', {});

    i = 1;
    N = numel(byteStream);
    packetLengthBytes = c.otaPacketLengthBytes;
    while i <= N
        if i + c.otaAccessCodeLengthBytes - 1 > N
            break;
        end

        if ~isequal(byteStream(i:i+c.otaAccessCodeLengthBytes-1), accessCodeBytes)
            i = i + 1;
            continue;
        end

        if i + packetLengthBytes - 1 > N
            break;
        end

        cand = byteStream(i:i+packetLengthBytes-1);
        res = parse_ota_packet(cand, accessCodeBytes);

        if res.ok
            item.startIndex = i;
            item.packetBytes = cand;
            item.payloadBytes = res.payloadBytes(:);
            item.result = res;
            packets(end+1) = item; %#ok<AGROW>
            i = i + packetLengthBytes;
        else
            i = i + 1;
        end
    end
end
