function cycleSpec = get_source_protocol_cycle(cfg, jammerKey, sequenceBase)
    if nargin < 2
        jammerKey = "";
    end
    if nargin < 3
        sequenceBase = uint8(0);
    end
    sequenceBase = uint8(sequenceBase);

    if string(cfg.waveType) == "broadcast"
        frameDefs = local_get_broadcast_frame_defs(cfg, sequenceBase);
    elseif string(cfg.waveType) == "jammer"
        frameDefs = local_get_jammer_frame_defs(cfg, jammerKey);
    else
        error("未知的 waveType：'%s'。", cfg.waveType);
    end

    numFrames = numel(frameDefs);
    protocolFrames = repmat(struct( ...
        'cmdId', uint16(0), ...
        'seq', uint8(0), ...
        'label', "", ...
        'type', "", ...
        'dataBytes', uint8([]), ...
        'frameBytes', uint8([]), ...
        'summary', ""), numFrames, 1);

    protocolStreamBytes = uint8([]);
    for k = 1:numFrames
        frameBytes = build_protocol_frame(frameDefs(k).cmdId, frameDefs(k).seq, frameDefs(k).dataBytes);
        parsed = parse_protocol_frame(frameBytes);

        protocolFrames(k).cmdId = frameDefs(k).cmdId;
        protocolFrames(k).seq = frameDefs(k).seq;
        protocolFrames(k).label = frameDefs(k).label;
        protocolFrames(k).type = frameDefs(k).type;
        protocolFrames(k).dataBytes = frameDefs(k).dataBytes(:);
        protocolFrames(k).frameBytes = frameBytes(:);
        protocolFrames(k).summary = protocol_frame_to_text(parsed);

        protocolStreamBytes = [protocolStreamBytes; frameBytes(:)]; %#ok<AGROW>
    end

    fillerBytes = uint8([]);
    if string(cfg.waveType) == "jammer"
        [protocolStreamBytes, fillerBytes] = local_align_jammer_stream_to_official_layout(protocolStreamBytes, cfg);
    end

    if numel(protocolStreamBytes) ~= cfg.payloadBytesPerCycle
        error('源 %s 单周期协议流长度应为 %d 字节，当前为 %d。', ...
            cfg.name, cfg.payloadBytesPerCycle, numel(protocolStreamBytes));
    end

    otaSpec = build_ota_stream(protocolStreamBytes, cfg.accessCodeBytes);
    cycleSpec = struct( ...
        'waveType', cfg.waveType, ...
        'opponentColor', cfg.opponentColor, ...
        'protocolFrames', protocolFrames, ...
        'protocolStreamBytes', protocolStreamBytes(:), ...
        'protocolStreamBits', bytes_to_bits_msb(protocolStreamBytes(:)), ...
        'fillerBytes', fillerBytes(:), ...
        'otaSpec', otaSpec, ...
        'payloadBytesPerCycle', cfg.payloadBytesPerCycle, ...
        'protocolFrameCountPerCycle', numel(protocolFrames), ...
        'otaPacketCountPerCycle', cfg.payloadBytesPerCycle / cfg.otaPayloadLengthBytes, ...
        'cycleDurationSec', 1 / cfg.cycleRateHz);
end

function frameDefs = local_get_broadcast_frame_defs(cfg, sequenceBase)
    robotFields = local_get_robot_field_defaults(cfg.opponentColor);
    frameSeq = uint8(mod(double(sequenceBase) + (0:4), 256));
    frameDefs = [
        local_frame_def(uint16(hex2dec('0A01')), frameSeq(1), "opponent_positions", "broadcast_positions", local_build_0A01_data(robotFields))
        local_frame_def(uint16(hex2dec('0A02')), frameSeq(2), "opponent_hp", "broadcast_hp", local_build_0A02_data(robotFields))
        local_frame_def(uint16(hex2dec('0A03')), frameSeq(3), "opponent_projectiles", "broadcast_projectiles", local_build_0A03_data(robotFields))
        local_frame_def(uint16(hex2dec('0A04')), frameSeq(4), "economy_and_buff_points", "broadcast_economy", local_build_0A04_data(robotFields))
        local_frame_def(uint16(hex2dec('0A05')), frameSeq(5), "robot_buffs", "broadcast_buffs", local_build_0A05_data(robotFields))
    ];
end

function frameDefs = local_get_jammer_frame_defs(cfg, jammerKey)
    jammerKey = string(jammerKey);
    if strlength(jammerKey) == 0
        jammerKey = local_get_default_jammer_key(cfg.name);
    elseif strlength(jammerKey) ~= 6 || isempty(regexp(char(jammerKey), '^[0-9A-Za-z]{6}$', 'once'))
        error("JammerKey 必须是 6 字节 ASCII 字母或数字。");
    end
    frameDefs = local_frame_def( ...
        uint16(hex2dec('0A06')), uint8(7), ...
        "jammer_key", "jammer_key", uint8(char(jammerKey)));
end

function frameDef = local_frame_def(cmdId, seq, label, typeName, dataBytes)
    frameDef = struct( ...
        'cmdId', cmdId, ...
        'seq', seq, ...
        'label', label, ...
        'type', typeName, ...
        'dataBytes', uint8(dataBytes(:)));
end

function robotFields = local_get_robot_field_defaults(opponentColor)
    if string(opponentColor) == "blue"
        posVals = uint16([1320 260 1180 420 1040 580 940 760 760 910 1580 540]);
        hpVals = uint16([320 280 260 250 0 420]);
        ammoVals = uint16([450 520 510 150 620]);
        economyRemain = uint16(180);
        economyTotal = uint16(540);
        buffStatusBits = uint32(hex2dec('00004A35'));
    else
        posVals = uint16([520 760 640 590 790 430 930 250 1180 120 260 480]);
        hpVals = uint16([310 295 255 245 0 410]);
        ammoVals = uint16([430 500 490 140 600]);
        economyRemain = uint16(165);
        economyTotal = uint16(500);
        buffStatusBits = uint32(hex2dec('00009316'));
    end

    robotFields = struct( ...
        'positionVals', posVals, ...
        'hpVals', hpVals, ...
        'ammoVals', ammoVals, ...
        'economyRemain', economyRemain, ...
        'economyTotal', economyTotal, ...
        'buffStatusBits', buffStatusBits, ...
        'mainStatusVals', uint8([0 0 0 0 0]), ...
        'hero', struct('regen', uint8(10), 'cooling', uint16(90), 'defense', uint8(20), 'negDefense', uint8(0), 'attack', uint16(35)), ...
        'engineer', struct('regen', uint8(15), 'cooling', uint16(60), 'defense', uint8(10), 'negDefense', uint8(5), 'attack', uint16(15)), ...
        'infantry3', struct('regen', uint8(8), 'cooling', uint16(75), 'defense', uint8(12), 'negDefense', uint8(0), 'attack', uint16(20)), ...
        'infantry4', struct('regen', uint8(6), 'cooling', uint16(72), 'defense', uint8(10), 'negDefense', uint8(4), 'attack', uint16(18)), ...
        'sentry', struct('regen', uint8(5), 'cooling', uint16(120), 'defense', uint8(25), 'negDefense', uint8(0), 'attack', uint16(40), 'pose', uint8(2)));
end

function dataBytes = local_build_0A01_data(robotFields)
    dataBytes = local_uint16_array_to_bytes(uint16(robotFields.positionVals(:).'));
end

function dataBytes = local_build_0A02_data(robotFields)
    dataBytes = local_uint16_array_to_bytes(uint16(robotFields.hpVals(:).'));
end

function dataBytes = local_build_0A03_data(robotFields)
    dataBytes = local_uint16_array_to_bytes(uint16(robotFields.ammoVals(:).'));
end

function dataBytes = local_build_0A04_data(robotFields)
    dataBytes = [ ...
        local_uint16_to_bytes(uint16(robotFields.economyRemain)); ...
        local_uint16_to_bytes(uint16(robotFields.economyTotal)); ...
        local_uint32_to_bytes(uint32(robotFields.buffStatusBits)) ];
    dataBytes = uint8(dataBytes(:));
end

function dataBytes = local_build_0A05_data(robotFields)
    dataBytes = [ ...
        local_pack_buff(robotFields.hero); ...
        local_pack_buff(robotFields.engineer); ...
        local_pack_buff(robotFields.infantry3); ...
        local_pack_buff(robotFields.infantry4); ...
        local_pack_buff(robotFields.sentry); ...
        uint8(robotFields.sentry.pose); ...
        uint8(robotFields.mainStatusVals(:)) ];
    dataBytes = uint8(dataBytes(:));
end

function bytes = local_pack_buff(info)
    bytes = [ ...
        uint8(info.regen); ...
        local_uint16_to_bytes(uint16(info.cooling)); ...
        uint8(info.defense); ...
        uint8(info.negDefense); ...
        local_uint16_to_bytes(uint16(info.attack)) ];
    bytes = uint8(bytes(:));
end

function bytes = local_uint16_array_to_bytes(values)
    values = uint16(values(:));
    bytes = zeros(2 * numel(values), 1, 'uint8');
    for k = 1:numel(values)
        idx = 2*k - 1;
        bytes(idx:idx+1) = local_uint16_to_bytes(values(k));
    end
end

function bytes = local_uint16_to_bytes(value)
    bytes = typecast(uint16(value), 'uint8').';
    bytes = bytes(:);
end

function bytes = local_uint32_to_bytes(value)
    bytes = typecast(uint32(value), 'uint8').';
    bytes = bytes(:);
end

function [streamBytes, fillerBytes] = local_align_jammer_stream_to_official_layout(frameBytes, cfg)
    officialLeadingFillerLen = 10;
    frameBytes = uint8(frameBytes(:));
    prefixBytes = uint8(repmat(hex2dec('CC'), officialLeadingFillerLen, 1));

    suffixLen = cfg.payloadBytesPerCycle - officialLeadingFillerLen - numel(frameBytes);
    if suffixLen < 0
        error('干扰波有效帧长度超过单周期 %g 字节限制。', cfg.payloadBytesPerCycle);
    end

    suffixBytes = uint8(repmat(hex2dec('DD'), suffixLen, 1));
    streamBytes = [prefixBytes; frameBytes; suffixBytes];
    fillerBytes = [prefixBytes; suffixBytes];
end

function jammerKey = local_get_default_jammer_key(sourceName)
    alphabet = ['0':'9' 'A':'Z'];
    seed = sum(double(char(sourceName)));
    jammerKey = repmat('0', 1, 6);
    for k = 1:6
        idx = mod(seed + 13*k + 7*k^2, numel(alphabet)) + 1;
        jammerKey(k) = alphabet(idx);
    end
    jammerKey = string(jammerKey);
end
