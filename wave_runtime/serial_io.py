"""Linux 裁判串口自动探测、重连与非阻塞收发。"""

from __future__ import annotations

import glob
import time
from pathlib import Path
from typing import Callable


class SerialEndpoint:
    """串口断线后自动重连；自动探测会排除 Pluto 虚拟串口。"""

    def __init__(
        self,
        port: str = "auto",
        baudrate: int = 115200,
        retry_interval_sec: float = 1.0,
        logger: Callable[[str], None] = print,
    ):
        self.requested_port = port
        self.baudrate = baudrate
        self.retry_interval_sec = retry_interval_sec
        self.logger = logger
        self.serial = None
        self.current_port: str | None = None
        self.next_retry_at = 0.0
        self.rx_bytes = 0
        self.tx_bytes = 0

    @property
    def connected(self) -> bool:
        return self.serial is not None and bool(getattr(self.serial, "is_open", False))

    def _load_pyserial(self):
        try:
            import serial
            from serial.tools import list_ports
        except ImportError as exc:
            raise RuntimeError("缺少 pyserial，请执行 python3 -m pip install pyserial") from exc
        return serial, list_ports

    @staticmethod
    def _looks_like_pluto(text: str) -> bool:
        lowered = text.lower()
        return "pluto" in lowered or "adalm" in lowered or "analog devices" in lowered

    def _candidate_ports(self, list_ports) -> list[str]:
        if self.requested_port != "auto":
            return [self.requested_port]
        preferred = ["/dev/referee", "/dev/ttyACM0", "/dev/ttyACM1", "/dev/ttyACM2"]
        preferred.extend(sorted(glob.glob("/dev/ttyUSB*")))
        metadata = {item.device: item for item in list_ports.comports()}
        candidates: list[str] = []
        for port in preferred:
            if not Path(port).exists() and port not in metadata:
                continue
            item = metadata.get(port)
            description = " ".join(
                str(value or "")
                for value in (
                    getattr(item, "description", ""),
                    getattr(item, "manufacturer", ""),
                    getattr(item, "product", ""),
                    getattr(item, "hwid", ""),
                )
            )
            is_pluto_usb = (
                getattr(item, "vid", None) == 0x0456
                and getattr(item, "pid", None) == 0xB673
            )
            if is_pluto_usb or self._looks_like_pluto(description):
                self.logger(f"[serial] 跳过 Pluto 虚拟串口：{port}")
                continue
            if port not in candidates:
                candidates.append(port)
        return candidates

    def ensure_open(self, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        if self.connected:
            return True
        if now < self.next_retry_at:
            return False
        self.next_retry_at = now + self.retry_interval_sec
        serial, list_ports = self._load_pyserial()
        for port in self._candidate_ports(list_ports):
            try:
                if "://" in port:
                    handle = serial.serial_for_url(
                        port,
                        baudrate=self.baudrate,
                        timeout=0,
                        write_timeout=0.5,
                    )
                else:
                    handle = serial.Serial(
                        port,
                        baudrate=self.baudrate,
                        timeout=0,
                        write_timeout=0.5,
                    )
                self.serial = handle
                self.current_port = port
                self.logger(f"[serial] 已连接裁判串口：{port} @ {self.baudrate}")
                return True
            except (OSError, serial.SerialException) as exc:
                self.logger(f"[serial] 无法打开 {port}：{exc}")
        return False

    def read_available(self) -> bytes:
        if not self.connected:
            return b""
        try:
            count = int(getattr(self.serial, "in_waiting", 0))
            if count <= 0:
                return b""
            data = bytes(self.serial.read(count))
            self.rx_bytes += len(data)
            return data
        except Exception as exc:
            self._drop(f"读取失败：{exc}")
            return b""

    def write(self, data: bytes) -> bool:
        if not self.connected:
            return False
        try:
            written = int(self.serial.write(data))
            self.tx_bytes += written
            return written == len(data)
        except Exception as exc:
            self._drop(f"写入失败：{exc}")
            return False

    def _drop(self, reason: str) -> None:
        self.logger(f"[serial] 连接断开：{reason}")
        self.close()
        self.next_retry_at = time.monotonic() + self.retry_interval_sec

    def close(self) -> None:
        handle, self.serial = self.serial, None
        self.current_port = None
        if handle is not None:
            try:
                handle.close()
            except Exception:
                pass
