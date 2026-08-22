function radioCtx = resolve_pluto_radio_id(requestedRadioID, roleName)
    if nargin < 2 || strlength(string(roleName)) == 0
        roleName = "tx";
    end

    roleCode = local_normalize_role_code(roleName);
    roleLabel = local_get_role_label(roleCode);
    requestedRadioID = strtrim(string(requestedRadioID));
    usedDefaultRoute = false;

    if strlength(requestedRadioID) == 0 || any(strcmpi(requestedRadioID, ["auto", "default"]))
        requestedRadioID = local_get_default_ip(roleCode);
        usedDefaultRoute = true;
    end

    if ~startsWith(requestedRadioID, "ip:")
        error("%s", local_build_non_ip_error(roleLabel, requestedRadioID));
    end

    ipAddr = strtrim(extractAfter(requestedRadioID, "ip:"));
    if strlength(ipAddr) == 0
        error("%s", local_build_empty_ip_error(roleLabel, requestedRadioID));
    end

    radioCtx = struct( ...
        'roleName', roleLabel, ...
        'requestedRadioID', requestedRadioID, ...
        'resolvedRadioID', requestedRadioID, ...
        'usedDefaultRoute', usedDefaultRoute);
end

function roleCode = local_normalize_role_code(roleName)
    roleName = lower(strtrim(string(roleName)));
    if any(strcmp(roleName, ["rx", "recv", "receiver"]))
        roleCode = "rx";
    else
        roleCode = "tx";
    end
end

function roleLabel = local_get_role_label(roleCode)
    if roleCode == "rx"
        roleLabel = "Pluto 接收端";
    else
        roleLabel = "Pluto 发射端";
    end
end

function radioID = local_get_default_ip(roleCode)
    if roleCode == "rx"
        radioID = "ip:192.168.2.1";
    else
        radioID = "ip:192.168.2.1";
    end
end

function msg = local_build_non_ip_error(roleLabel, requestedRadioID)
    msg = sprintf([ ...
        '%s 当前仅支持基于 IP 的 Pluto 访问。\n' ...
        '请使用形如 RadioID=''ip:192.168.2.1'' 或 RadioID=''ip:192.168.3.1'' 的写法。\n' ...
        '项目默认配置为：正式信息波接收端 ip:192.168.2.1，正式干扰波接收端 ip:192.168.3.1。\n' ...
        '当前传入值：%s'], char(roleLabel), char(requestedRadioID));
end

function msg = local_build_empty_ip_error(roleLabel, requestedRadioID)
    msg = sprintf([ ...
        '%s 的 RadioID 缺少 IP 地址。\n' ...
        '请使用完整写法，例如 RadioID=''ip:192.168.2.1'' 或 RadioID=''ip:192.168.3.1''。\n' ...
        '当前传入值：%s'], char(roleLabel), char(requestedRadioID));
end
