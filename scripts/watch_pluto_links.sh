#!/usr/bin/env bash
set -euo pipefail

INTERVAL_SEC="${INTERVAL_SEC:-30}"

while true; do
    printf '[%(%F %T)T] ' -1
    for address in 192.168.2.1 192.168.3.1; do
        if ping -c 1 -W 1 "$address" >/dev/null 2>&1 \
            && iio_info -u "ip:$address" >/dev/null 2>&1; then
            printf '%s=online ' "$address"
        else
            printf '%s=offline ' "$address"
        fi
    done
    printf '\n'
    sleep "$INTERVAL_SEC"
done
