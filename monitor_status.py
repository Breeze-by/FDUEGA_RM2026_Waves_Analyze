#!/usr/bin/env python3
"""读取独立运行时状态文件并持续显示比赛链路状态。"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Pluto 电磁波比赛状态监视器")
    parser.add_argument("--status-json", default=".runtime/status.json")
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args()
    path = Path(args.status_json)
    last_text = ""
    try:
        while True:
            try:
                status = json.loads(path.read_text(encoding="utf-8"))
                text = (
                    f"stage={status['game_progress']} id={status['robot_id']} {status['faction']} "
                    f"level={status['own_encrypt_level']} key_pending={int(status['key_verify_pending'])} "
                    f"valid=0x{status['info_valid_mask']:02X} fresh=0x{status['info_fresh_mask']:02X} "
                    f"position_fresh={int(status['position_fresh'])} "
                    f"serial={status['serial_connected']}({status['serial_port'] or '-'}) "
                    f"tx={status['tx_counts']}"
                )
            except (OSError, ValueError, KeyError):
                text = f"等待状态文件：{path}"
            if text != last_text:
                print(text, flush=True)
                last_text = text
            time.sleep(max(0.1, args.interval))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
