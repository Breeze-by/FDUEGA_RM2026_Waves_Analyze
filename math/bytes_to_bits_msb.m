function bits = bytes_to_bits_msb(b)
    b = uint8(b(:));
    bits = zeros(numel(b)*8, 1);
    for k = 1:8
        bits(k:8:end) = bitget(b, 8-k+1);
    end
end