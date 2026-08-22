from __future__ import annotations

import argparse
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

from tests.test_state import make_snapshot
from wave_runtime.service import WaveRuntimeService


def free_udp_port() -> int:
    handle = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    handle.bind(("127.0.0.1", 0))
    port = handle.getsockname()[1]
    handle.close()
    return port


def make_args(status_json: str, run_seconds: float = 0.15) -> argparse.Namespace:
    return argparse.Namespace(
        serial_port="auto",
        baudrate=115200,
        no_serial=True,
        udp_listen_host="127.0.0.1",
        udp_listen_port=free_udp_port(),
        status_host="127.0.0.1",
        jammer_status_port=free_udp_port(),
        info_status_port=free_udp_port(),
        status_rate_hz=20.0,
        status_json=status_json,
        manual_game_progress=4,
        manual_robot_id=9,
        manual_encrypt_level=1,
        run_seconds=run_seconds,
    )


class FakeSerial:
    connected = True
    current_port = "fake"

    def __init__(self):
        self.frames: list[bytes] = []

    def write(self, frame: bytes) -> bool:
        self.frames.append(bytes(frame))
        return True

    def close(self) -> None:
        self.connected = False


class ServiceTests(unittest.TestCase):
    def test_udp_event_loop_receives_key_and_sends_both_status_copies(self):
        with tempfile.TemporaryDirectory() as directory:
            args = make_args(str(Path(directory) / "status.json"))
            receivers = []
            for port in (args.jammer_status_port, args.info_status_port):
                handle = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                handle.bind(("127.0.0.1", port))
                handle.settimeout(1.0)
                receivers.append(handle)
            service = WaveRuntimeService(args)
            thread = threading.Thread(target=service.run)
            thread.start()
            sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sender.sendto(b"\x02ABCDEF", ("127.0.0.1", args.udp_listen_port))
            packets = [handle.recvfrom(16)[0] for handle in receivers]
            thread.join(timeout=2.0)
            sender.close()
            for handle in receivers:
                handle.close()
            self.assertFalse(thread.is_alive())
            self.assertEqual(packets, [b"\x04\x09\x01", b"\x04\x09\x01"])
            self.assertTrue(service.state.key_verify_pending)
            self.assertTrue(Path(args.status_json).exists())

    def test_interactive_scheduler_matches_formal_slot_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            args = make_args(str(Path(directory) / "status.json"), run_seconds=0)
            service = WaveRuntimeService(args)
            fake = FakeSerial()
            service.serial = fake
            payloads = (bytes(24), bytes(12), bytes(10), bytes(8), bytes(41))
            service.state.handle_wave_datagram(make_snapshot(payloads), time.monotonic())
            for _ in range(28):
                service._run_interactive_slot(time.monotonic())
            self.assertEqual(service.tx_counts.get("0x02AA"), 5)
            self.assertEqual(service.tx_counts.get("0x0233"), 5)
            self.assertEqual(service.tx_counts.get("0x02AB"), 13)
            self.assertNotIn("0x0121", service.tx_counts)

            service.state.handle_wave_datagram(b"\x02ABCDEF", time.monotonic())
            service.tx_counts.clear()
            service.slot_credits = [0, 0, 0, 0, 0]
            for _ in range(28):
                service._run_interactive_slot(time.monotonic())
            self.assertEqual(service.tx_counts.get("0x0121"), 5)
            self.assertEqual(service.tx_counts.get("0x02AB"), 8)
            service.rx_socket.close()
            service.tx_socket.close()


if __name__ == "__main__":
    unittest.main()
