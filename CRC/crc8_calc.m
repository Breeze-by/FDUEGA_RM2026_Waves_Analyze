function crc = crc8_calc(bytes, crc)
    table = get_crc8_table();
    bytes = uint8(bytes(:));
    for k = 1:numel(bytes)
        idx = bitxor(crc, bytes(k));
        crc = table(double(idx) + 1);
    end
end