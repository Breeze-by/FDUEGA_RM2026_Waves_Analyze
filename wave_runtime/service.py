"""比赛状态、MATLAB UDP 和裁判串口之间的独立桥接服务。"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import time
from pathlib import Path

from .protocol import (
    RefereeStreamDecoder,
    pack_engineer_info,
    pack_multicast,
    pack_radar_decision,
    pack_radar_map,
    pack_sentry_flags,
)
from .serial_io import SerialEndpoint
from .state import WaveBusinessState


def _env_int(name: str, default: int) -> int:
    return int(os.environ.get(name, str(default)))


def _env_float(name: str, default: float) -> float:
    return float(os.environ.get(name, str(default)))


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Pluto 电磁波独立比赛通信服务")
    parser.add_argument("--serial-port", default=os.environ.get("REFEREE_PORT", "auto"))
    parser.add_argument("--baudrate", type=int, default=_env_int("REFEREE_BAUDRATE", 115200))
    parser.add_argument("--no-serial", action="store_true", help="仅用于离线联调，不打开裁判串口")
    parser.add_argument("--udp-listen-host", default="127.0.0.1")
    parser.add_argument("--udp-listen-port", type=int, default=_env_int("WAVE_RETURN_PORT", 5007))
    parser.add_argument("--status-host", default="127.0.0.1")
    parser.add_argument("--jammer-status-port", type=int, default=_env_int("JAMMER_STATUS_PORT", 5006))
    parser.add_argument("--info-status-port", type=int, default=_env_int("INFO_STATUS_PORT", 5008))
    parser.add_argument("--status-rate-hz", type=float, default=_env_float("STATUS_RATE_HZ", 10.0))
    parser.add_argument("--status-json", default=os.environ.get("WAVE_STATUS_JSON", ".runtime/status.json"))
    parser.add_argument("--manual-game-progress", type=int, default=0)
    parser.add_argument("--manual-robot-id", type=int, default=0)
    parser.add_argument("--manual-encrypt-level", type=int, default=0)
    parser.add_argument("--run-seconds", type=float, default=float("inf"))
    return parser


class WaveRuntimeService:
    """单线程事件循环保证 UDP 到达顺序和串口发送间隔。"""

    INTERACTIVE_RATE_HZ = 28.0
    MAP_RATE_HZ = 5.0

    def __init__(self, args: argparse.Namespace):
        if args.status_rate_hz <= 0:
            raise ValueError("status-rate-hz 必须大于 0")
        self.args = args
        self.state = WaveBusinessState()
        self.state.game_progress = args.manual_game_progress & 0x0F
        self.state.robot_id = args.manual_robot_id & 0xFF
        self.state.own_encrypt_level = args.manual_encrypt_level & 0x03
        self.decoder = RefereeStreamDecoder()
        self.serial = None if args.no_serial else SerialEndpoint(args.serial_port, args.baudrate, logger=self.log)
        self.rx_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.rx_socket.bind((args.udp_listen_host, args.udp_listen_port))
        self.rx_socket.setblocking(False)
        self.tx_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.stop_requested = False
        self.seq = 0
        self.tx_counts: dict[str, int] = {}
        self.slot_credits = [0, 0, 0, 0, 0]
        self.slot_weights = (5, 5, 5, 8, 5)
        self.multicast_credits = [0, 0, 0]
        self.last_log_at = 0.0

    @staticmethod
    def log(message: str) -> None:
        print(message, flush=True)

    def _next_seq(self) -> int:
        value = self.seq
        self.seq = (self.seq + 1) & 0xFF
        return value

    def _valid_radar_id(self) -> bool:
        return self.state.robot_id in (9, 109)

    def _send_serial(self, kind: str, frame: bytes) -> bool:
        if self.serial is None or not self.serial.connected:
            return False
        if self.serial.write(frame):
            self.tx_counts[kind] = self.tx_counts.get(kind, 0) + 1
            return True
        return False

    def _drain_wave_udp(self, now: float) -> None:
        while True:
            try:
                payload, _sender = self.rx_socket.recvfrom(2048)
            except BlockingIOError:
                return
            result = self.state.handle_wave_datagram(payload, now)
            if result == "key":
                self.log(
                    f"[wave] 收到 {self.state.own_encrypt_level} 级密钥："
                    f"{self.state.key[1:7].decode('ascii', errors='replace')}"
                )

    def _poll_serial(self, now: float) -> None:
        if self.serial is None:
            return
        self.serial.ensure_open(now)
        chunk = self.serial.read_available()
        if not chunk:
            return
        for frame in self.decoder.feed(chunk):
            self.state.handle_referee_frame(frame, now)

    def _send_status(self) -> None:
        payload = self.state.status_packet().pack()
        for port in (self.args.jammer_status_port, self.args.info_status_port):
            self.tx_socket.sendto(payload, (self.args.status_host, port))

    def _select_multicast_receiver(self) -> int:
        weights = (1, 2, 2)
        self.multicast_credits = [credit + weight for credit, weight in zip(self.multicast_credits, weights)]
        index = max(range(3), key=self.multicast_credits.__getitem__)
        self.multicast_credits[index] -= sum(weights)
        return self.state.multicast_receivers()[index]

    def _send_multicast(self) -> bool:
        if not self.state.multicast_data_ready():
            return False
        receiver = self._select_multicast_receiver()
        frame = pack_multicast(
            self.state.robot_id,
            receiver,
            self.state.build_multicast_user_data(),
            self._next_seq(),
        )
        return self._send_serial("0x02AB", frame)

    def _run_interactive_slot(self, now: float) -> None:
        if not (self.state.is_active and self._valid_radar_id()):
            return
        self.slot_credits = [credit + weight for credit, weight in zip(self.slot_credits, self.slot_weights)]
        index = max(range(len(self.slot_credits)), key=self.slot_credits.__getitem__)
        self.slot_credits[index] -= sum(self.slot_weights)
        if index == 0:
            if self.state.key_verify_pending:
                frame = pack_radar_decision(self.state.robot_id, self.state.key, self._next_seq())
                self._send_serial("0x0121", frame)
            else:
                self._send_multicast()
        elif index == 1 and self.state.engineer_data_ready():
            frame = pack_engineer_info(
                self.state.robot_id,
                self.state.build_engineer_user_data(),
                self._next_seq(),
            )
            self._send_serial("0x02AA", frame)
        elif index == 2:
            frame = pack_sentry_flags(
                self.state.robot_id,
                self.state.build_sentry_flags(now),
                self._next_seq(),
            )
            self._send_serial("0x0233", frame)
        elif index == 3:
            self._send_multicast()
        # index 4 是保留槽，不发送与电磁波无关的飞镖消息。

    def _send_map_if_ready(self, now: float) -> None:
        if not (self.state.is_active and self._valid_radar_id()):
            return
        coordinates = self.state.radar_map_coordinates(now)
        if coordinates is not None:
            self._send_serial("0x0305", pack_radar_map(coordinates, self._next_seq()))

    def _write_status_json(self, now: float) -> None:
        path = Path(self.args.status_json)
        path.parent.mkdir(parents=True, exist_ok=True)
        content = self.state.to_status_dict(now)
        content.update(
            {
                "serial_connected": bool(self.serial and self.serial.connected),
                "serial_port": self.serial.current_port if self.serial else None,
                "serial_crc_errors": self.decoder.crc_error_count,
                "tx_counts": dict(self.tx_counts),
                "updated_unix": time.time(),
            }
        )
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps(content, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary.replace(path)

    def run(self) -> None:
        started = time.monotonic()
        status_period = 1.0 / self.args.status_rate_hz
        interactive_period = 1.0 / self.INTERACTIVE_RATE_HZ
        map_period = 1.0 / self.MAP_RATE_HZ
        next_status = next_interactive = next_map = next_json = started
        self.log(
            f"[runtime] UDP 监听 {self.args.udp_listen_host}:{self.args.udp_listen_port}，"
            f"状态输出 {self.args.status_host}:{self.args.jammer_status_port}/{self.args.info_status_port}"
        )
        try:
            while not self.stop_requested and time.monotonic() - started < self.args.run_seconds:
                now = time.monotonic()
                self._poll_serial(now)
                self._drain_wave_udp(now)
                if now >= next_status:
                    self._send_status()
                    next_status = now + status_period
                if now >= next_interactive:
                    self._run_interactive_slot(now)
                    next_interactive = now + interactive_period
                if now >= next_map:
                    self._send_map_if_ready(now)
                    next_map = now + map_period
                if now >= next_json:
                    self._write_status_json(now)
                    if now - self.last_log_at >= 1.0:
                        status = self.state.to_status_dict(now)
                        self.log(
                            f"[runtime] stage={status['game_progress']} id={status['robot_id']} "
                            f"level={status['own_encrypt_level']} valid=0x{status['info_valid_mask']:02X} "
                            f"fresh=0x{status['info_fresh_mask']:02X} serial={bool(self.serial and self.serial.connected)}"
                        )
                        self.last_log_at = now
                    next_json = now + 1.0
                time.sleep(0.002)
        finally:
            self._write_status_json(time.monotonic())
            if self.serial is not None:
                self.serial.close()
            self.rx_socket.close()
            self.tx_socket.close()


def main(argv: list[str] | None = None) -> None:
    args = build_argument_parser().parse_args(argv)
    service = WaveRuntimeService(args)

    def request_stop(_signum, _frame) -> None:
        service.stop_requested = True

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    service.run()


if __name__ == "__main__":
    main()
