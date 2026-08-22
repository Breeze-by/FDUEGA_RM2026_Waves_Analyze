function packetBytes = build_ota_packet(payloadBytes, accessCodeBytes)
    c = get_protocol_constants();
    payloadBytes = uint8(payloadBytes(:));
    accessCodeBytes = uint8(accessCodeBytes(:));

    if numel(payloadBytes) ~= c.otaPayloadLengthBytes
        error('OTA payload length must be exactly 15 bytes.');
    end

    lenBytes = local_uint16_to_be(uint16(numel(payloadBytes)));
    headerBytes = [lenBytes; lenBytes];
    packetBytes = [accessCodeBytes; headerBytes; payloadBytes];
end

function bytes = local_uint16_to_be(v)
    bytes = uint8([bitshift(v, -8); bitand(v, uint16(255))]);
end
