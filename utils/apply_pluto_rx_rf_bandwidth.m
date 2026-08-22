function actualBandwidthHz = apply_pluto_rx_rf_bandwidth(rx, radioID, rfBandwidthHz)
    % MATLAB 完成 Pluto 初始化后再设置 RX 模拟滤波带宽，避免初始化覆盖该值。
    actualBandwidthHz = NaN;
    if isempty(rfBandwidthHz) || ~isfinite(double(rfBandwidthHz)) || ...
            double(rfBandwidthHz) <= 0
        return;
    end

    rfBandwidthHz = round(double(rfBandwidthHz));
    propertyApplied = false;
    if isprop(rx, 'RFBandwidth')
        rx.RFBandwidth = rfBandwidthHz;
        propertyApplied = true;
    end

    radioID = string(radioID);
    if isempty(regexp(char(radioID), '^(ip|usb):[A-Za-z0-9._:-]+$', 'once'))
        if propertyApplied
            actualBandwidthHz = rfBandwidthHz;
            fprintf("Pluto RX RF 带宽已通过对象属性设置为 %.3f MHz；当前设备地址不支持 IIO 读回。\n", ...
                rfBandwidthHz / 1e6);
            return;
        end
        error('无法设置 Pluto RX RF 带宽：设备地址格式不受支持：%s', radioID);
    end

    if ~propertyApplied
        writeCmd = sprintf( ...
            'iio_attr -u "%s" -i -c ad9361-phy voltage0 rf_bandwidth %d', ...
            char(radioID), rfBandwidthHz);
        [writeStatus, writeOutput] = system(writeCmd);
        if writeStatus ~= 0
            error('通过 IIO 设置 Pluto RX RF 带宽失败：%s', strtrim(writeOutput));
        end
    end

    readCmd = sprintf( ...
        'iio_attr -u "%s" -i -c ad9361-phy voltage0 rf_bandwidth', ...
        char(radioID));
    [readStatus, readOutput] = system(readCmd);
    actualBandwidthHz = str2double(strtrim(readOutput));
    if readStatus ~= 0 || ~isfinite(actualBandwidthHz)
        error('Pluto RX RF 带宽已下发，但读取实际值失败：%s', strtrim(readOutput));
    end
    if round(actualBandwidthHz) ~= rfBandwidthHz
        error('Pluto RX RF 带宽校验失败：目标=%d Hz，实际=%d Hz。', ...
            rfBandwidthHz, round(actualBandwidthHz));
    end

    fprintf("Pluto RX RF 带宽已通过 IIO 设置为 %.3f MHz（实际 %.3f MHz）。\n", ...
        rfBandwidthHz / 1e6, actualBandwidthHz / 1e6);
end
