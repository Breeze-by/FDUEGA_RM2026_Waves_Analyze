function crc = crc16_calc(bytes)
    table = get_crc16_table();
    c = get_protocol_constants();
    crc = c.protocolCrc16Init;
    bytes = uint8(bytes(:));
    for k = 1:numel(bytes)
        idx = bitand(bitxor(crc, uint16(bytes(k))), uint16(255));
        crc = bitxor(bitshift(crc, -8), table(double(idx) + 1));
    end
end
