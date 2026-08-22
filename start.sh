#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${WAVE_CONFIG:-$PROJECT_DIR/config/wave.env}"
RUNTIME_DIR="${WAVE_RUNTIME_DIR:-$PROJECT_DIR/.runtime}"
LOG_DIR="$RUNTIME_DIR/logs"
STATUS_JSON="$RUNTIME_DIR/status.json"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "正式运行仅支持 Linux；Windows 只用于离线单元测试。" >&2
    exit 1
fi
if [[ -f "$CONFIG_FILE" ]]; then
    # 配置文件仅允许 KEY=VALUE，不执行项目外脚本。
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

INFO_RX_RADIO_ID="${INFO_RX_RADIO_ID:-ip:192.168.2.1}"
JAMMER_RX_RADIO_ID="${JAMMER_RX_RADIO_ID:-ip:192.168.3.1}"
REFEREE_PORT="${REFEREE_PORT:-auto}"
REFEREE_BAUDRATE="${REFEREE_BAUDRATE:-115200}"
JAMMER_STATUS_PORT="${JAMMER_STATUS_PORT:-5006}"
WAVE_RETURN_PORT="${WAVE_RETURN_PORT:-5007}"
INFO_STATUS_PORT="${INFO_STATUS_PORT:-5008}"
INFO_RELAY_PORT="${INFO_RELAY_PORT:-5010}"
INFO_FAILOVER_RELAY_PORT="${INFO_FAILOVER_RELAY_PORT:-5012}"
INFO_CAPTURE_SAMPLE_RATE_HZ="${INFO_CAPTURE_SAMPLE_RATE_HZ:-1000000}"
JAMMER_CAPTURE_SAMPLE_RATE_HZ="${JAMMER_CAPTURE_SAMPLE_RATE_HZ:-2000000}"
INFO_STREAM_DECODE_WINDOW_SEC="${INFO_STREAM_DECODE_WINDOW_SEC:-0.25}"
INFO_STREAM_DECODE_STRIDE_SEC="${INFO_STREAM_DECODE_STRIDE_SEC:-0.10}"
INFO_STREAM_RING_BUFFER_SEC="${INFO_STREAM_RING_BUFFER_SEC:-1.0}"
INFO_STREAM_WORKER_COUNT="${INFO_STREAM_WORKER_COUNT:-2}"
INFO_FRESH_WINDOW_SEC="${INFO_FRESH_WINDOW_SEC:-3.0}"
RADIO_CHECK_INTERVAL_SEC="${RADIO_CHECK_INTERVAL_SEC:-2.0}"
PREWARM_INFO_BEFORE_MATCH="${PREWARM_INFO_BEFORE_MATCH:-true}"
PREWARM_JAMMER_BEFORE_MATCH="${PREWARM_JAMMER_BEFORE_MATCH:-true}"
START_LINK_MONITOR="${START_LINK_MONITOR:-1}"
MATLAB_BIN="${MATLAB_BIN:-matlab}"

for command in python3 "$MATLAB_BIN" iio_info; do
    command -v "$command" >/dev/null || { echo "缺少运行依赖：$command" >&2; exit 1; }
done
python3 -c 'import serial' 2>/dev/null || {
    echo "缺少 pyserial，请执行：python3 -m pip install pyserial" >&2
    exit 1
}

mkdir -p "$LOG_DIR"
: >"$LOG_DIR/runtime.log"
: >"$LOG_DIR/relay.log"
: >"$LOG_DIR/info_matlab.log"
: >"$LOG_DIR/jammer_matlab.log"

PIDS=()
cleanup() {
    trap - INT TERM EXIT
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${PIDS[@]:-}"; do
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup INT TERM EXIT

cd "$PROJECT_DIR"
export INFO_CAPTURE_SAMPLE_RATE_HZ
export PYTHONUNBUFFERED=1

python3 wave_service.py \
    --serial-port "$REFEREE_PORT" \
    --baudrate "$REFEREE_BAUDRATE" \
    --udp-listen-port "$WAVE_RETURN_PORT" \
    --jammer-status-port "$JAMMER_STATUS_PORT" \
    --info-status-port "$INFO_STATUS_PORT" \
    --status-json "$STATUS_JSON" \
    >>"$LOG_DIR/runtime.log" 2>&1 &
PIDS+=("$!")

python3 info_wave_udp_relay.py \
    --listen-port "$INFO_RELAY_PORT" \
    --failover-listen-port "$INFO_FAILOVER_RELAY_PORT" \
    --remote-port "$WAVE_RETURN_PORT" \
    --rate-hz 10 \
    --fresh-timeout-sec "$INFO_FRESH_WINDOW_SEC" \
    >>"$LOG_DIR/relay.log" 2>&1 &
PIDS+=("$!")

COMMON_MATLAB_ARGS="'KeyRemoteHost','127.0.0.1','KeyRemotePort',$WAVE_RETURN_PORT,'RunTimeSec',inf,'DecodeInfo',true,'DecodeJammer',true,'InfoRxRadioID','$INFO_RX_RADIO_ID','JammerRxRadioID','$JAMMER_RX_RADIO_ID','InfoStreamDecodeWindowSec',$INFO_STREAM_DECODE_WINDOW_SEC,'InfoStreamDecodeStrideSec',$INFO_STREAM_DECODE_STRIDE_SEC,'InfoStreamRingBufferSec',$INFO_STREAM_RING_BUFFER_SEC,'InfoStreamWorkerCount',$INFO_STREAM_WORKER_COUNT,'InfoFreshWindowSec',$INFO_FRESH_WINDOW_SEC,'CaptureSampleRateHz',$JAMMER_CAPTURE_SAMPLE_RATE_HZ,'InfoCaptureSampleRateHz',$INFO_CAPTURE_SAMPLE_RATE_HZ,'RadioCheckIntervalSec',$RADIO_CHECK_INTERVAL_SEC,'SuppressRecvConsole',true,'ShowRecvPlots',false"

"$MATLAB_BIN" -batch "project_setup; state=FSK_RRC_AutoMatchUdp('ListenPort',$JAMMER_STATUS_PORT,'InfoRemoteHost','127.0.0.1','InfoRemotePort',$INFO_FAILOVER_RELAY_PORT,'FailoverRole','jammer_primary','PrewarmInfoBeforeMatch',false,'PrewarmJammerBeforeMatch',$PREWARM_JAMMER_BEFORE_MATCH,$COMMON_MATLAB_ARGS); disp(state);" \
    >>"$LOG_DIR/jammer_matlab.log" 2>&1 &
PIDS+=("$!")

"$MATLAB_BIN" -batch "project_setup; state=FSK_RRC_AutoMatchUdp('ListenPort',$INFO_STATUS_PORT,'InfoRemoteHost','127.0.0.1','InfoRemotePort',$INFO_RELAY_PORT,'FailoverRole','info_primary','PrewarmInfoBeforeMatch',$PREWARM_INFO_BEFORE_MATCH,'PrewarmJammerBeforeMatch',false,$COMMON_MATLAB_ARGS); disp(state);" \
    >>"$LOG_DIR/info_matlab.log" 2>&1 &
PIDS+=("$!")

if [[ "$START_LINK_MONITOR" == "1" ]]; then
    "$PROJECT_DIR/scripts/watch_pluto_links.sh" >>"$LOG_DIR/pluto_links.log" 2>&1 &
    PIDS+=("$!")
fi

echo "电磁波独立正式流程已启动"
echo "  信息波 Pluto: $INFO_RX_RADIO_ID"
echo "  干扰波 Pluto: $JAMMER_RX_RADIO_ID"
echo "  裁判串口: $REFEREE_PORT"
echo "  状态: $STATUS_JSON"
echo "  日志: $LOG_DIR"
echo "按 Ctrl-C 停止全部进程并释放 Pluto。"

set +e
wait -n "${PIDS[@]}"
exit_code=$?
set -e
echo "某个正式进程已退出（code=$exit_code），正在停止整组进程。" >&2
exit "$exit_code"
