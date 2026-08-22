function [isMatch, detail, matchedInfo] = protocol_payload_matches_expected(result, payloadInfo)
    detail = "";
    isMatch = false;
    matchedInfo = struct([]);

    if ~result.ok
        detail = "frame_invalid";
        return;
    end

    if isempty(payloadInfo)
        detail = "no_expected_payload";
        return;
    end

    payloadList = payloadInfo(:);
    hadCmdId = false;
    for k = 1:numel(payloadList)
        info = payloadList(k);
        if ~isfield(info, 'cmdId') || uint16(info.cmdId) ~= result.cmdId
            continue;
        end

        hadCmdId = true;
        seqOk = true;
        if isfield(info, 'seq')
            seqOk = uint8(info.seq) == result.seq;
        end

        dataOk = local_compare_payload_bytes(result, info);
        if seqOk && dataOk
            isMatch = true;
            detail = "payload_match";
            matchedInfo = info;
            return;
        end
    end

    if hadCmdId
        detail = "payload_mismatch";
    else
        detail = "cmd_id_mismatch";
    end
end

function dataOk = local_compare_payload_bytes(result, info)
    if isfield(info, 'dataBytes')
        dataOk = isequal(uint8(info.dataBytes(:)), uint8(result.dataBytes(:)));
        return;
    end

    if isfield(info, 'frameBytes')
        expRes = parse_protocol_frame(info.frameBytes(:));
        dataOk = isequal(uint8(expRes.dataBytes(:)), uint8(result.dataBytes(:)));
        return;
    end

    if isfield(info, 'asciiText')
        dataOk = strcmp(string(info.asciiText), string(result.asciiText));
        return;
    end

    dataOk = false;
end
