function textOut = protocol_frame_to_text(result)
    if ~isfield(result, 'ok') || ~result.ok
        textOut = "无效协议帧";
        return;
    end

    switch string(result.type)
        case "broadcast_positions"
            p = result.payload;
            textOut = sprintf("英雄(%d,%d)，工程(%d,%d)，哨兵(%d,%d)", ...
                p.heroX, p.heroY, p.engineerX, p.engineerY, p.sentryX, p.sentryY);
        case "broadcast_hp"
            p = result.payload;
            textOut = sprintf("血量：英雄=%d，工程=%d，步兵3=%d，步兵4=%d，哨兵=%d", ...
                p.heroHp, p.engineerHp, p.infantry3Hp, p.infantry4Hp, p.sentryHp);
        case "broadcast_projectiles"
            p = result.payload;
            textOut = sprintf("弹量：英雄=%d，步兵3=%d，步兵4=%d，空中=%d，哨兵=%d", ...
                p.heroAmmo, p.infantry3Ammo, p.infantry4Ammo, p.aerialAmmo, p.sentryAmmo);
        case "broadcast_economy"
            p = result.payload;
            textOut = sprintf("经济：剩余金币=%d，总金币=%d，增益点状态=0x%08X", ...
                p.remainCoins, p.totalCoins, uint32(p.buffStatusBits));
        case "broadcast_buffs"
            p = result.payload;
            textOut = sprintf("增益：英雄攻击=%d，工程防御=%d，哨兵姿态=%d，主要状态=%d/%d/%d/%d/%d", ...
                p.heroAttack, p.engineerDefense, p.sentryPose, ...
                p.heroMainStatus, p.engineerMainStatus, p.infantry3MainStatus, ...
                p.infantry4MainStatus, p.sentryMainStatus);
        case "jammer_key"
            textOut = sprintf("干扰密钥：%s", result.asciiText);
        otherwise
            textOut = sprintf("命令码=0x%04X，数据长度=%d", result.cmdId, result.dataLength);
    end

    textOut = string(textOut);
end
