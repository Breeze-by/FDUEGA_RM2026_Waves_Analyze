function frame = build_protocol_frame(cmdId, seq, dataBytes)
    c = get_protocol_constants();
    dataBytes = uint8(dataBytes(:));
    dataLength = uint16(numel(dataBytes));

    frame = zeros(c.protocolHeaderLengthBytes + c.protocolCmdLengthBytes + numel(dataBytes) + c.protocolTailLengthBytes, 1, 'uint8');
    frame(1) = c.protocolSofByte;
    frame(2:3) = local_uint16_to_bytes(dataLength, c.businessFieldEndian);
    frame(4) = uint8(seq);
    frame(5) = crc8_calc(frame(1:4), c.protocolCrc8Init);
    frame(6:7) = local_uint16_to_bytes(uint16(cmdId), c.businessFieldEndian);
    frame(8:7+numel(dataBytes)) = dataBytes;

    crc16 = crc16_calc(frame(1:end-2));
    frame(end-1:end) = local_uint16_to_bytes(uint16(crc16), c.protocolCrc16Endian);
end

function bytes = local_uint16_to_bytes(value, endianMode)
    bytes = typecast(uint16(value), 'uint8').';
    if string(endianMode) == "big"
        bytes = flipud(bytes(:));
    else
        bytes = bytes(:);
    end
end
