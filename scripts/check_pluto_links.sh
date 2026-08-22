#!/usr/bin/env bash
set -euo pipefail

command -v ip >/dev/null || { echo "缺少 iproute2 的 ip 命令" >&2; exit 1; }
command -v iio_info >/dev/null || { echo "缺少 libiio-utils 的 iio_info" >&2; exit 1; }

echo "== Pluto 网络地址与路由 =="
ip -br addr | grep -E '192\.168\.[23]\.' || true
ip route show | grep -E '192\.168\.[23]\.0/24' || true

echo "== 连通性 =="
for address in 192.168.2.1 192.168.3.1; do
    if ping -c 1 -W 1 "$address" >/dev/null 2>&1; then
        echo "$address: ping 正常"
    else
        echo "$address: ping 失败"
    fi
done

echo "== IIO context =="
iio_info -s || true

echo "== USB 电源状态 =="
for device in /sys/bus/usb/devices/*; do
    [[ -f "$device/idVendor" && -f "$device/idProduct" ]] || continue
    [[ "$(<"$device/idVendor")" == "0456" && "$(<"$device/idProduct")" == "b673" ]] || continue
    echo "$device serial=$(cat "$device/serial" 2>/dev/null || true) control=$(cat "$device/power/control" 2>/dev/null || true)"
done
