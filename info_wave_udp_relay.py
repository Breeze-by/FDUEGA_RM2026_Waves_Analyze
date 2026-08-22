#!/usr/bin/env python3
"""将两路 MATLAB 信息波快照仲裁后，以固定频率转发给比赛运行时。"""

from __future__ import annotations

import argparse
import signal
import socket
import time
from dataclasses import dataclass

INFO_SIZE = 102
INFO_HEADER = b"IF\x03"
VALID_MASK = 0x1F
UPDATE_HOLD_TICKS = 3


@dataclass
class SourceState:
    name: str
    snapshot: bytes | None = None
    received_at: float | None = None
    count: int = 0


class RelayEngine:
    """无套接字依赖的主备仲裁和新鲜度处理核心。"""

    def __init__(self, primary_timeout_sec: float = 0.5, fresh_timeout_sec: float = 3.0):
        self.primary_timeout_sec = primary_timeout_sec
        self.fresh_timeout_sec = fresh_timeout_sec
        self.sources = {
            "primary": SourceState("primary"),
            "failover": SourceState("failover"),
        }
        self.active_source: str | None = None
        self.snapshot = INFO_HEADER + bytes(INFO_SIZE - len(INFO_HEADER))
        self.snapshot_at: float | None = None
        self.pending_update_index = 0
        self.pending_update_seq = 0
        self.pending_update_ticks = 0

    @staticmethod
    def valid(payload: bytes) -> bool:
        return len(payload) == INFO_SIZE and payload[:3] == INFO_HEADER

    def receive(self, source_name: str, payload: bytes, now: float) -> bool:
        if source_name not in self.sources or not self.valid(payload):
            return False
        source = self.sources[source_name]
        source.snapshot = bytes(payload)
        source.received_at = now
        source.count += 1
        primary = self.sources["primary"]
        primary_silent = primary.received_at is None or now - primary.received_at >= self.primary_timeout_sec
        if source_name == "primary" or self.active_source != "primary" or primary_silent:
            self._activate(source, now)
            self._latch_update(payload)
        return True

    def _activate(self, source: SourceState, now: float) -> None:
        if source.snapshot is None:
            return
        if self.active_source != source.name:
            self.pending_update_index = 0
            self.pending_update_seq = 0
            self.pending_update_ticks = 0
        self.active_source = source.name
        self.snapshot = source.snapshot
        self.snapshot_at = source.received_at if source.received_at is not None else now

    def _latch_update(self, payload: bytes) -> None:
        if payload[3] & VALID_MASK == 0:
            self.pending_update_index = 0
            self.pending_update_seq = 0
            self.pending_update_ticks = 0
            return
        update_index = (payload[3] >> 5) & 0x07
        if update_index and (update_index == 1 or self.pending_update_index != 1):
            self.pending_update_index = update_index
            self.pending_update_seq = int.from_bytes(payload[5:7], "little")
            self.pending_update_ticks = UPDATE_HOLD_TICKS

    def output(self, now: float) -> bytes:
        primary = self.sources["primary"]
        failover = self.sources["failover"]
        if (
            self.active_source == "primary"
            and primary.received_at is not None
            and now - primary.received_at >= self.primary_timeout_sec
            and failover.snapshot is not None
            and failover.received_at is not None
            and now - failover.received_at < self.primary_timeout_sec
        ):
            self._activate(failover, now)
            self._latch_update(failover.snapshot)

        output = bytearray(self.snapshot)
        if self.pending_update_ticks > 0:
            output[3] = (output[3] & VALID_MASK) | (self.pending_update_index << 5)
            output[5:7] = self.pending_update_seq.to_bytes(2, "little")
            self.pending_update_ticks -= 1
            if self.pending_update_ticks == 0:
                self.pending_update_index = 0
        else:
            output[3] &= VALID_MASK
        if self.snapshot_at is not None and now - self.snapshot_at > self.fresh_timeout_sec:
            output[4] = 0
        return bytes(output)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="InfoMsgBag 固定 10 Hz 主备转发")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=5010)
    parser.add_argument("--failover-listen-port", type=int, default=5012)
    parser.add_argument("--primary-timeout-sec", type=float, default=0.5)
    parser.add_argument("--remote-host", default="127.0.0.1")
    parser.add_argument("--remote-port", type=int, default=5007)
    parser.add_argument("--rate-hz", type=float, default=10.0)
    parser.add_argument("--fresh-timeout-sec", type=float, default=3.0)
    return parser.parse_args()


def run(args: argparse.Namespace) -> None:
    if args.rate_hz <= 0 or args.primary_timeout_sec <= 0 or args.fresh_timeout_sec <= 0:
        raise ValueError("频率与超时时间必须大于 0")
    if args.listen_port == args.failover_listen_port:
        raise ValueError("主信息源与接管源不能使用相同端口")
    engine = RelayEngine(args.primary_timeout_sec, args.fresh_timeout_sec)
    sockets: dict[socket.socket, str] = {}
    for name, port in (("primary", args.listen_port), ("failover", args.failover_listen_port)):
        if port <= 0:
            continue
        handle = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        handle.bind((args.listen_host, port))
        handle.setblocking(False)
        sockets[handle] = name
    tx_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    stopped = False

    def request_stop(_signum, _frame) -> None:
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    period = 1.0 / args.rate_hz
    next_send = time.monotonic()
    sent = 0
    last_log = next_send
    print(
        f"[relay] primary={args.listen_host}:{args.listen_port} "
        f"failover={args.listen_host}:{args.failover_listen_port} "
        f"output={args.remote_host}:{args.remote_port} rate={args.rate_hz:g}Hz",
        flush=True,
    )
    try:
        while not stopped:
            for handle, name in sockets.items():
                while True:
                    try:
                        payload, _sender = handle.recvfrom(2048)
                    except BlockingIOError:
                        break
                    engine.receive(name, payload, time.monotonic())
            now = time.monotonic()
            if now >= next_send:
                tx_socket.sendto(engine.output(now), (args.remote_host, args.remote_port))
                sent += 1
                next_send = now + period
            if now - last_log >= 1.0:
                valid_mask = engine.snapshot[3] & VALID_MASK
                fresh_mask = engine.snapshot[4] & VALID_MASK
                if engine.snapshot_at is not None and now - engine.snapshot_at > engine.fresh_timeout_sec:
                    fresh_mask = 0
                print(
                    f"[relay] active={engine.active_source or 'none'} "
                    f"primary={engine.sources['primary'].count} failover={engine.sources['failover'].count} "
                    f"sent={sent} valid=0x{valid_mask:02X} fresh=0x{fresh_mask:02X}",
                    flush=True,
                )
                last_log = now
            time.sleep(0.002)
    finally:
        for handle in sockets:
            handle.close()
        tx_socket.close()


if __name__ == "__main__":
    run(parse_args())
