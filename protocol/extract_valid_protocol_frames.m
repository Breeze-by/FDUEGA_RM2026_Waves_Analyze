function frames = extract_valid_protocol_frames(byteStream)
    byteStream = uint8(byteStream(:));
    frames = struct('startIndex', {}, 'frameBytes', {}, 'result', {});

    i = 1;
    N = numel(byteStream);
    c = get_protocol_constants();
    while i <= N
        if byteStream(i) ~= c.protocolSofByte
            i = i + 1;
            continue;
        end

        if i + c.protocolHeaderLengthBytes - 1 > N
            break;
        end

        dataLength = local_read_uint16(byteStream(i+1:i+2), c.businessFieldEndian);
        totalLen = c.protocolHeaderLengthBytes + c.protocolCmdLengthBytes + double(dataLength) + c.protocolTailLengthBytes;

        if i + totalLen - 1 > N
            i = i + 1;
            continue;
        end

        cand = byteStream(i:i+totalLen-1);
        res = parse_protocol_frame(cand);

        if res.ok
            item.startIndex = i;
            item.frameBytes = cand;
            item.result = res;
            frames(end+1) = item; %#ok<AGROW>
            i = i + totalLen;
        else
            i = i + 1;
        end
    end
end

function value = local_read_uint16(bytes, endianMode)
    bytes = uint8(bytes(:));
    if string(endianMode) == "big"
        bytes = flipud(bytes);
    end
    value = typecast(bytes, 'uint16');
end
