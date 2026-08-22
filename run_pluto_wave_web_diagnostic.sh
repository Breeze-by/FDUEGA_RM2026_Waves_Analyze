#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${WAVE_DIAGNOSTIC_WEB_PORT:-8766}"

echo "Pluto 波源 Web 实时诊断：http://127.0.0.1:${PORT}"
echo "A/B 通道可独立启动；停止服务请按 Ctrl+C。"
exec python3 "$SCRIPT_DIR/tool/live_wave_debugger/server.py" --host 127.0.0.1 --port "$PORT"
