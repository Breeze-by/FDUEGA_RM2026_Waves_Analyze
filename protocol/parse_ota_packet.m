function result = parse_ota_packet(packetBytes, accessCodeBytes)
    c = get_protocol_constants();
    packetBytes = uint8(packetBytes(:));
    accessCodeBytes = uint8(accessCodeBytes(:));

    result = struct( ...
        'ok', false, ...
        'complete', false, ...
        'accessCodeOk', false, ...
        'headerOk', false, ...
        'headerBytes', uint8([]), ...
        'payloadLength1', uint16(0), ...
        'payloadLength2', uint16(0), ...
        'payloadBytes', uint8([]), ...
        'totalLength', uint16(0), ...
        'errorCode', "", ...
        'rawHex', "");

    result.rawHex = string(upper(reshape(dec2hex(packetBytes).', 1, [])));
    if numel(packetBytes) < c.otaPacketLengthBytes
        result.errorCode = "short_packet";
        return;
    end

    accessCodeEnd = c.otaAccessCodeLengthBytes;
    headerStart = accessCodeEnd + 1;
    headerEnd = accessCodeEnd + c.otaHeaderLengthBytes;
    payloadStart = headerEnd + 1;

    result.accessCodeOk = isequal(packetBytes(1:accessCodeEnd), accessCodeBytes);
    result.headerBytes = packetBytes(headerStart:headerEnd);
    result.payloadLength1 = local_be_to_uint16(packetBytes(headerStart:headerStart+1));
    result.payloadLength2 = local_be_to_uint16(packetBytes(headerStart+2:headerEnd));
    result.headerOk = result.payloadLength1 == result.payloadLength2 && ...
        isequal(result.headerBytes(:), c.otaHeaderBytes) && ...
        result.payloadLength1 == uint16(c.otaPayloadLengthBytes);
    result.totalLength = uint16(12 + double(result.payloadLength1));

    if numel(packetBytes) < double(result.totalLength)
        result.errorCode = "truncated_payload";
        return;
    end

    result.complete = true;
    result.payloadBytes = packetBytes(payloadStart:payloadStart+double(result.payloadLength1)-1);
    result.ok = result.accessCodeOk && result.headerOk;
    if result.ok
        result.errorCode = "";
    elseif ~result.accessCodeOk
        result.errorCode = "access_code_mismatch";
    else
        result.errorCode = "invalid_header";
    end
end

function v = local_be_to_uint16(bytes)
    bytes = uint8(bytes(:));
    v = bitor(bitshift(uint16(bytes(1)), 8), uint16(bytes(2)));
end
