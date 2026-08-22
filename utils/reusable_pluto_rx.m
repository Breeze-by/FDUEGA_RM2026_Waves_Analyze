function [rx, reused] = reusable_pluto_rx(action, cfg)
    % 在同一 MATLAB 进程内复用 Pluto RX System object，避免每轮采集重新连接设备。
    persistent cachedRx cachedCfg

    action = lower(strtrim(string(action)));
    if action == "release"
        local_release(cachedRx);
        cachedRx = [];
        cachedCfg = [];
        rx = [];
        reused = false;
        return;
    end

    if action ~= "acquire" || nargin < 2 || isempty(cfg)
        error('reusable_pluto_rx 仅支持 acquire(cfg) 或 release。');
    end

    if ~isempty(cachedRx) && isequaln(cachedCfg, cfg)
        rx = cachedRx;
        reused = true;
        return;
    end

    if ~isempty(cachedRx)
        fprintf(['Pluto RX 配置变化，先释放旧接收器再重建：' ...
            'radio=%s center=%.3f MHz bandwidth=%.3f MHz。\n'], ...
            string(cachedCfg.radioID), cachedCfg.centerFrequency / 1e6, ...
            cachedCfg.rfBandwidthHz / 1e6);
    end
    local_release(cachedRx);
    cachedRx = [];
    cachedCfg = [];
    pause(0.1);

    if cfg.useAGC
        if string(cfg.agcMode) == "fast"
            gainSource = 'AGC Fast Attack';
        else
            gainSource = 'AGC Slow Attack';
        end
        rx = sdrrx('Pluto', ...
            'RadioID', char(cfg.radioID), ...
            'CenterFrequency', cfg.centerFrequency, ...
            'BasebandSampleRate', cfg.sampleRate, ...
            'SamplesPerFrame', cfg.samplesPerFrame, ...
            'OutputDataType', 'double', ...
            'GainSource', gainSource);
    else
        rx = sdrrx('Pluto', ...
            'RadioID', char(cfg.radioID), ...
            'CenterFrequency', cfg.centerFrequency, ...
            'BasebandSampleRate', cfg.sampleRate, ...
            'SamplesPerFrame', cfg.samplesPerFrame, ...
            'OutputDataType', 'double', ...
            'GainSource', 'Manual', ...
            'Gain', cfg.gainDB);
    end

    cachedRx = rx;
    cachedCfg = cfg;
    reused = false;
end

function local_release(rx)
    if isempty(rx)
        return;
    end
    try
        release(rx);
    catch
    end
end
