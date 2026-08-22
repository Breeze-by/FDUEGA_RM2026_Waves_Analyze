#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "请使用 sudo 运行：sudo $0" >&2
    exit 1
fi

RULE_PATH=/etc/udev/rules.d/99-pluto-stability.rules
tee "$RULE_PATH" >/dev/null <<'RULES'
# 禁止 ADALM-Pluto USB 自动休眠。
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="0456", ATTR{idProduct}=="b673", TEST=="power/control", ATTR{power/control}="on"
# 阻止 ModemManager 抢占 Pluto 的 ttyACM 接口。
ACTION=="add|change", ATTRS{idVendor}=="0456", ATTRS{idProduct}=="b673", ENV{ID_MM_DEVICE_IGNORE}="1"
ACTION=="add|change", SUBSYSTEM=="tty", ATTRS{idVendor}=="0456", ATTRS{idProduct}=="b673", ENV{ID_MM_DEVICE_IGNORE}="1"
RULES

udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --attr-match=idVendor=0456 --attr-match=idProduct=b673 || true
echo "已安装 $RULE_PATH"
