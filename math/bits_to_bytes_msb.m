function bytes = bits_to_bytes_msb(bits)
    bits = bits(:);
    n = floor(numel(bits)/8);
    bits = bits(1:8*n);

    if n == 0
        bytes = uint8([]);
        return;
    end

    B = reshape(bits, 8, []).';
    bytes = zeros(n,1,'uint8');
    for i = 1:n
        v = uint8(0);
        for k = 1:8
            v = bitor(bitshift(v,1), uint8(B(i,k) ~= 0));
        end
        bytes(i) = v;
    end
end