#!/usr/bin/env python3
"""Pluto 正式接收链路 Web 实时诊断服务，A/B 通道可独立启停。"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import signal
import subprocess
import tempfile
import threading
import time
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


WEB_ROOT = Path(__file__).resolve().parent
STATIC_ROOT = WEB_ROOT / "static"
WAVE_ROOT = WEB_ROOT.parents[1]
PROJECT_ROOT = WAVE_ROOT
SOURCES = (
    {"value": "red_broadcast", "label": "红方信息波", "type": "信息波"},
    {"value": "red_l1_jammer", "label": "红方一级干扰波", "type": "干扰波"},
    {"value": "red_l2_jammer", "label": "红方二级干扰波", "type": "干扰波"},
    {"value": "red_l3_jammer", "label": "红方三级干扰波（发射源测试）", "type": "干扰波"},
    {"value": "blue_broadcast", "label": "蓝方信息波", "type": "信息波"},
    {"value": "blue_l1_jammer", "label": "蓝方一级干扰波", "type": "干扰波"},
    {"value": "blue_l2_jammer", "label": "蓝方二级干扰波", "type": "干扰波"},
    {"value": "blue_l3_jammer", "label": "蓝方三级干扰波（发射源测试）", "type": "干扰波"},
)
SOURCE_VALUES = {item["value"] for item in SOURCES}


def matlab_quote(value: str | Path) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def formal_wave_conflicts(ignore_pids: set[int]) -> list[str]:
    conflicts: list[str] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit() or int(entry.name) in ignore_pids:
            continue
        try:
            cmdline = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(
                "utf-8", errors="replace"
            )
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if "FSK_RRC_AutoMatchUdp" in cmdline:
            conflicts.append(f"PID {entry.name}: {cmdline[:180]}")
    return conflicts


class WorkerManager:
    def __init__(self, matlab_bin: str) -> None:
        self.matlab_bin = matlab_bin
        self.lock = threading.RLock()
        self.runtime_dir: Path | None = None
        self.workers: dict[str, subprocess.Popen[bytes]] = {}
        self.logs: dict[str, Any] = {}
        self.config: dict[str, dict[str, Any]] = {}
        self.started_at: dict[str, float] = {}

    def managed_pids(self) -> set[int]:
        return {os.getpid(), *(process.pid for process in self.workers.values())}

    def start_channel(self, channel: str, config: dict[str, Any]) -> dict[str, Any]:
        channel = self._validate_channel_name(channel)
        validated = self._validate_config(channel, config)
        with self.lock:
            conflicts = formal_wave_conflicts(self.managed_pids())
            if conflicts:
                raise RuntimeError(
                    "检测到正式比赛 wave 进程，Web 诊断拒绝抢占 Pluto：\n"
                    + "\n".join(conflicts)
                )
            for running_channel, running_config in self.config.items():
                if running_channel != channel and running_config["radioID"] == validated["radioID"]:
                    raise RuntimeError(f"{validated['radioID']} 已被通道 {running_channel} 占用")
            self._probe_pluto(validated["radioID"])
            self.stop_channel(channel)
            if self.runtime_dir is None:
                self.runtime_dir = Path(tempfile.mkdtemp(prefix="rm_wave_web_", dir="/tmp"))
            for suffix in ("json", "json.spectrum", "stop", "stdout"):
                path = self.runtime_dir / f"channel_{channel}.{suffix}"
                if path.exists():
                    path.unlink()
            self.config[channel] = validated
            self.started_at[channel] = time.time()
            try:
                output_path = self.runtime_dir / f"channel_{channel}.json"
                stop_path = self.runtime_dir / f"channel_{channel}.stop"
                log_path = self.runtime_dir / f"channel_{channel}.stdout"
                matlab_code = self._build_matlab_code(channel, validated, output_path, stop_path)
                log_handle = log_path.open("wb")
                process = subprocess.Popen(
                    [self.matlab_bin, "-batch", matlab_code], cwd=WAVE_ROOT,
                    stdout=log_handle, stderr=subprocess.STDOUT, start_new_session=True,
                )
                self.logs[channel] = log_handle
                self.workers[channel] = process
            except Exception:
                self.stop_channel(channel)
                raise
            return self.state()

    def stop_channel(self, channel: str) -> dict[str, Any]:
        channel = self._validate_channel_name(channel)
        with self.lock:
            process = self.workers.get(channel)
            if self.runtime_dir is not None and process is not None:
                (self.runtime_dir / f"channel_{channel}.stop").touch(exist_ok=True)
            if process is not None:
                try:
                    process.wait(timeout=3.0)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                        process.wait(timeout=3.0)
                    except (ProcessLookupError, subprocess.TimeoutExpired):
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait(timeout=2.0)
            handle = self.logs.pop(channel, None)
            if handle is not None:
                handle.close()
            self.workers.pop(channel, None)
            self.config.pop(channel, None)
            self.started_at.pop(channel, None)
            return self.state()

    def stop(self) -> dict[str, Any]:
        with self.lock:
            for channel in tuple(self.workers):
                self.stop_channel(channel)
            return self.state()

    def state(self) -> dict[str, Any]:
        with self.lock:
            channels: dict[str, Any] = {}
            for channel in ("A", "B"):
                process = self.workers.get(channel)
                snapshot = None
                spectrum_snapshot = None
                if self.runtime_dir is not None:
                    snapshot = read_json(self.runtime_dir / f"channel_{channel}.json")
                    spectrum_snapshot = read_json(
                        self.runtime_dir / f"channel_{channel}.json.spectrum"
                    )
                exit_code = None if process is None else process.poll()
                worker_error = None
                if process is not None and exit_code not in (None, 0) and self.runtime_dir is not None:
                    log_path = self.runtime_dir / f"channel_{channel}.stdout"
                    try:
                        worker_error = log_path.read_text(encoding="utf-8", errors="replace")[-2000:]
                    except OSError:
                        worker_error = "MATLAB worker 异常退出"
                channels[channel] = {
                    "processRunning": process is not None and process.poll() is None,
                    "exitCode": exit_code,
                    "workerError": worker_error,
                    "config": self.config.get(channel),
                    "startedAtUnixSec": self.started_at.get(channel),
                    "snapshot": snapshot,
                    "spectrumSnapshot": spectrum_snapshot,
                }
            return {
                "running": any(item["processRunning"] for item in channels.values()),
                "channels": channels,
                "serverUnixSec": time.time(),
            }

    @staticmethod
    def _validate_channel_name(channel: str) -> str:
        channel = channel.upper()
        if channel not in ("A", "B"):
            raise ValueError("通道仅支持 A 或 B")
        return channel

    def _validate_config(self, channel: str, raw: dict[str, Any]) -> dict[str, Any]:
        source = str(raw.get("sourceName", ""))
        radio = str(raw.get("radioID", ""))
        if source not in SOURCE_VALUES:
            raise ValueError(f"通道 {channel} 波源无效：{source}")
        if not radio.startswith("ip:"):
            raise ValueError(f"通道 {channel} Pluto 地址必须使用 ip:x.x.x.x")
        try:
            ipaddress.ip_address(radio.removeprefix("ip:"))
        except ValueError as exc:
            raise ValueError(f"通道 {channel} Pluto IP 无效：{radio}") from exc
        return {"sourceName": source, "radioID": radio}

    @staticmethod
    def _probe_pluto(radio: str) -> None:
        try:
            result = subprocess.run(
                ["iio_info", "-u", radio], capture_output=True, text=True,
                timeout=6.0, check=False,
            )
        except FileNotFoundError as exc:
            raise RuntimeError("系统缺少 iio_info，无法进行 Pluto 安全预检") from exc
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"Pluto {radio} 连接超时，未启动接收") from exc
        output = (result.stdout + "\n" + result.stderr).strip()
        if result.returncode != 0 or "ad9361-phy" not in output:
            detail = output[-800:] or "设备无响应"
            raise RuntimeError(f"未找到或无法打开 Pluto {radio}：{detail}")

    def _build_matlab_code(
        self,
        channel: str,
        config: dict[str, Any],
        output_path: Path,
        stop_path: Path,
    ) -> str:
        return (
            f"cd({matlab_quote(WAVE_ROOT)});"
            "FSK_RRC_WebDiagnosticWorker("
            f"'Channel',{matlab_quote(channel)},"
            f"'SourceName',{matlab_quote(config['sourceName'])},"
            f"'RxRadioID',{matlab_quote(config['radioID'])},"
            f"'OutputPath',{matlab_quote(output_path)},"
            f"'StopPath',{matlab_quote(stop_path)});"
        )


class LiveHandler(SimpleHTTPRequestHandler):
    server_version = "RMWaveLiveDebugger/1.0"

    @property
    def manager(self) -> WorkerManager:
        return self.server.manager  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[web] {self.address_string()} {fmt % args}")

    def do_GET(self) -> None:  # noqa: N802
        path = unquote(urlparse(self.path).path)
        if path == "/":
            self.serve_file(STATIC_ROOT / "index.html", "text/html; charset=utf-8")
        elif path == "/api/config":
            self.send_json({"sources": SOURCES, "projectRoot": str(PROJECT_ROOT)})
        elif path == "/api/state":
            self.send_json(self.manager.state())
        elif path.startswith("/static/"):
            target = (STATIC_ROOT / path.removeprefix("/static/")).resolve()
            if not str(target).startswith(str(STATIC_ROOT.resolve())):
                self.send_error(HTTPStatus.FORBIDDEN)
                return
            content_types = {
                ".css": "text/css; charset=utf-8",
                ".js": "application/javascript; charset=utf-8",
                ".html": "text/html; charset=utf-8",
            }
            self.serve_file(target, content_types.get(target.suffix, "application/octet-stream"))
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        path = unquote(urlparse(self.path).path)
        try:
            parts = path.strip("/").split("/")
            if len(parts) == 4 and parts[:2] == ["api", "channels"] and parts[3] == "start":
                self.send_json(self.manager.start_channel(parts[2], self.read_json_body()))
            elif len(parts) == 4 and parts[:2] == ["api", "channels"] and parts[3] == "stop":
                self.send_json(self.manager.stop_channel(parts[2]))
            else:
                self.send_error(HTTPStatus.NOT_FOUND)
        except (ValueError, RuntimeError) as exc:
            self.send_json({"error": str(exc)}, HTTPStatus.BAD_REQUEST)
        except Exception as exc:
            self.send_json({"error": f"服务异常：{exc}"}, HTTPStatus.INTERNAL_SERVER_ERROR)

    def read_json_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length).decode("utf-8")) if length else {}

    def serve_file(self, path: Path, content_type: str) -> None:
        if not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, value: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class LiveServer(ThreadingHTTPServer):
    manager: WorkerManager


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Pluto 官方波源 Web 实时诊断")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--matlab-bin", default="matlab")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manager = WorkerManager(args.matlab_bin)
    server = LiveServer((args.host, args.port), LiveHandler)
    server.manager = manager

    def request_stop(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    print(f"Pluto Web 实时诊断：http://{args.host}:{args.port}")
    print("此服务独立于正式 start.sh，网页启动接收时会检查进程互斥。")
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        manager.stop()
        server.server_close()


if __name__ == "__main__":
    main()
