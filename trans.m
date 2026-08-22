function txState = trans(level, color, varargin)
    % 手动发射干扰波入口。
    % 示例：
    %   trans(1)                      % 红方一级干扰波，默认 ip:192.168.2.1
    %   trans(2, "red", 'TxTimeSec', 10, 'ShowPlots', false)
    %   trans(3, "blue")             % 三级仅用于自制发射源测试

    if nargin < 1 || isempty(level)
        level = input("请输入干扰波等级 1/2/3：");
    end
    if nargin < 2 || strlength(string(color)) == 0
        color = "red";
    end

    level = double(level);
    color = lower(strtrim(string(color)));
    if ~ismember(level, [1 2 3])
        error("干扰波等级必须是 1、2 或 3。");
    end
    if ~ismember(color, ["red", "blue"])
        error("颜色必须是 red 或 blue。");
    end

    sourceName = sprintf("%s_l%d_jammer", color, level);
    fprintf("准备发射：%s，默认发射端 ip:192.168.2.1\n", sourceName);
    txState = FSK_RRC_Trans('SourceName', sourceName, 'RadioID', 'ip:192.168.2.1', varargin{:});
end
