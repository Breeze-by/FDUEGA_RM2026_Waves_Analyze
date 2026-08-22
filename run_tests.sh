#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

python3 -m unittest discover -s tests -v
python3 -m compileall -q wave_runtime wave_service.py info_wave_udp_relay.py monitor_status.py tool

if command -v matlab >/dev/null; then
    matlab -batch "cd('$PROJECT_DIR'); project_setup; addpath('tests'); run_matlab_tests"
else
    echo "未找到 MATLAB，已跳过 MATLAB 无硬件回归测试。"
fi

bash -n start.sh run_tests.sh run_pluto_wave_web_diagnostic.sh scripts/*.sh
echo "全部可用测试通过。"
