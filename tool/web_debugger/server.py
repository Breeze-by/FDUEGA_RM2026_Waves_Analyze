#!/usr/bin/env python3
"""Web debugger for the RM2026 Waves MATLAB project.

This server intentionally uses only the Python standard library. It serves a
single-page UI and launches MATLAB batch jobs through the bridge script in
matlab_bridge/web_run_task.m.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import threading
import time
import uuid
from datetime import datetime
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


WEB_ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = WEB_ROOT.parents[1]
STATIC_ROOT = WEB_ROOT / "static"
RUNS_ROOT = WEB_ROOT / "runs"
BRIDGE_SCRIPT = WEB_ROOT / "matlab_bridge" / "web_run_task.m"

SOURCES = [
    {"value": "red_broadcast", "label": "红方广播源", "type": "信息波"},
    {"value": "blue_broadcast", "label": "蓝方广播源", "type": "信息波"},
    {"value": "red_l1_jammer", "label": "红方一级干扰源", "type": "干扰波"},
    {"value": "red_l2_jammer", "label": "红方二级干扰源", "type": "干扰波"},
    {"value": "red_l3_jammer", "label": "红方三级干扰源（发射源测试）", "type": "干扰波"},
    {"value": "blue_l1_jammer", "label": "蓝方一级干扰源", "type": "干扰波"},
    {"value": "blue_l2_jammer", "label": "蓝方二级干扰源", "type": "干扰波"},
    {"value": "blue_l3_jammer", "label": "蓝方三级干扰源（发射源测试）", "type": "干扰波"},
]

DEFAULTS: dict[str, Any] = {
    "sources": SOURCES,
    "sim": {
        "SourceName": "red_broadcast",
        "EbN0dB_vec": "0:1:25",
        "ShowPlots": False,
        "UseMultipath": False,
        "H_chan": "[1 0 0.25*exp(1j*0.7)]",
        "UseFlatFade": False,
        "RepeatInBuffer": 40,
    },
    "tx": {
        "SourceName": "red_l1_jammer",
        "RadioID": "ip:192.168.2.1",
        "TxGain_dB": 0,
        "TxTimeSec": 2.0,
        "RepeatInBuffer": 40,
        "EnablePlutoTx": False,
        "ShowPlots": False,
    },
    "rx": {
        "SourceName": "red_l1_jammer",
        "RxRadioID": "ip:192.168.2.1",
        "UseAGC": True,
        "RxGain_dB": 20,
        "SamplesPerFrame": 50000,
        "WarmupFrames": 4,
        "CaptureTimeSec": 1.2,
        "BW_lpf": "",
        "EnablePlutoRx": True,
        "ShowPlots": False,
    },
    "auto_rx": {
        "GameStarted": False,
        "TeamColor": "red",
        "JammerLevel": 1,
        "RxRadioID": "ip:192.168.2.1",
        "UseAGC": True,
        "RxGain_dB": 20,
        "SamplesPerFrame": 50000,
        "WarmupFrames": 4,
        "CaptureTimeSec": 3.0,
        "BW_lpf": "",
        "EnablePlutoRx": True,
        "MaxAttempts": 0,
    },
}

TASK_LABELS = {"sim": "仿真", "tx": "发射/波形", "rx": "接收", "auto_rx": "自动解析"}
RUNNING: dict[str, subprocess.Popen[str]] = {}
RUNNING_LOCK = threading.Lock()


def now_text() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def safe_job_id(task: str) -> str:
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    return f"{ts}_{task}_{uuid.uuid4().hex[:8]}"


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def read_json(path: Path, fallback: Any = None) -> Any:
    try:
        return json.loads(read_text_compatible(path))
    except Exception:
        return fallback


def read_text_compatible(path: Path) -> str:
    data = path.read_bytes()
    for encoding in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def matlab_quote(value: Path | str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def make_status(job_dir: Path, **updates: Any) -> dict[str, Any]:
    status_path = job_dir / "status.json"
    current = read_json(status_path, {}) or {}
    current.update(updates)
    current["updatedAt"] = now_text()
    write_json(status_path, current)
    return current


def artifact_list(job_id: str, job_dir: Path) -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    for path in sorted(job_dir.iterdir()):
        if path.name in {"job.json", "status.json"} or path.is_dir():
            continue
        rel = f"/runs/{job_id}/{path.name}"
        items.append({"name": path.name, "url": rel})
    return items


def build_matlab_command(matlab_bin: str, job_json: Path, job_dir: Path) -> list[str]:
    bridge_dir = BRIDGE_SCRIPT.parent
    batch = (
        f"addpath({matlab_quote(bridge_dir)}); "
        f"web_run_task({matlab_quote(job_json)}, {matlab_quote(job_dir)});"
    )
    return [matlab_bin, "-batch", batch]


def run_job(job_id: str, matlab_bin: str) -> None:
    job_dir = RUNS_ROOT / job_id
    job_json = job_dir / "job.json"
    stdout_path = job_dir / "stdout.txt"
    started = time.time()
    make_status(job_dir, id=job_id, state="running", startedAt=now_text(), exitCode=None)

    cmd = build_matlab_command(matlab_bin, job_json, job_dir)
    with stdout_path.open("wb") as log:
        log.write(f"[{now_text()}] command: {' '.join(cmd)}\n\n".encode("utf-8"))
        log.flush()
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=str(PROJECT_ROOT),
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            with RUNNING_LOCK:
                RUNNING[job_id] = proc
            exit_code = proc.wait()
            state = "completed" if exit_code == 0 else "failed"
            make_status(
                job_dir,
                state=state,
                exitCode=exit_code,
                finishedAt=now_text(),
                durationSec=round(time.time() - started, 3),
            )
        except Exception as exc:
            log.write(f"\n[{now_text()}] server error: {exc}\n".encode("utf-8"))
            make_status(
                job_dir,
                state="failed",
                exitCode=-1,
                error=str(exc),
                finishedAt=now_text(),
                durationSec=round(time.time() - started, 3),
            )
        finally:
            with RUNNING_LOCK:
                RUNNING.pop(job_id, None)


class DebuggerHandler(SimpleHTTPRequestHandler):
    server_version = "RMWebDebugger/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{now_text()}] {self.address_string()} {fmt % args}")

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        if path == "/":
            self.serve_file(STATIC_ROOT / "index.html", "text/html; charset=utf-8")
            return
        if path.startswith("/static/"):
            self.serve_static(path.removeprefix("/static/"))
            return
        if path == "/api/config":
            self.send_json({"projectRoot": str(PROJECT_ROOT), **DEFAULTS})
            return
        if path == "/api/jobs":
            self.send_json({"jobs": self.list_jobs()})
            return
        if path.startswith("/api/jobs/"):
            self.handle_job_get(path)
            return
        if path.startswith("/runs/"):
            self.serve_run_file(path.removeprefix("/runs/"))
            return

        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        if path == "/api/jobs":
            self.create_job()
            return
        if path.startswith("/api/jobs/") and path.endswith("/stop"):
            job_id = path.split("/")[3]
            self.stop_job(job_id)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def serve_static(self, rel: str) -> None:
        target = (STATIC_ROOT / rel).resolve()
        if not str(target).startswith(str(STATIC_ROOT.resolve())):
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        ctype = "text/plain; charset=utf-8"
        if target.suffix == ".html":
            ctype = "text/html; charset=utf-8"
        elif target.suffix == ".css":
            ctype = "text/css; charset=utf-8"
        elif target.suffix == ".js":
            ctype = "application/javascript; charset=utf-8"
        self.serve_file(target, ctype)

    def serve_run_file(self, rel: str) -> None:
        target = (RUNS_ROOT / rel).resolve()
        if not str(target).startswith(str(RUNS_ROOT.resolve())):
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        ctype = "application/octet-stream"
        if target.suffix == ".json":
            ctype = "application/json; charset=utf-8"
        elif target.suffix == ".txt":
            ctype = "text/plain; charset=utf-8"
        elif target.suffix == ".png":
            ctype = "image/png"
        elif target.suffix == ".csv":
            ctype = "text/csv; charset=utf-8"
        if target.suffix in {".txt", ".log"}:
            self.serve_text_file(target, ctype)
        else:
            self.serve_file(target, ctype)

    def serve_file(self, path: Path, content_type: str) -> None:
        if not path.exists() or not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def serve_text_file(self, path: Path, content_type: str) -> None:
        if not path.exists() or not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        data = read_text_compatible(path).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_body_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def send_json(self, data: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def create_job(self) -> None:
        try:
            body = self.read_body_json()
            task = str(body.get("task", "")).strip()
            if task not in TASK_LABELS:
                self.send_json({"error": "unknown task"}, HTTPStatus.BAD_REQUEST)
                return
            params = body.get("params", {})
            if not isinstance(params, dict):
                self.send_json({"error": "params must be an object"}, HTTPStatus.BAD_REQUEST)
                return
            matlab_bin = str(body.get("matlabBin") or "matlab")

            job_id = safe_job_id(task)
            job_dir = RUNS_ROOT / job_id
            job_dir.mkdir(parents=True, exist_ok=True)
            job = {
                "id": job_id,
                "task": task,
                "taskLabel": TASK_LABELS[task],
                "params": params,
                "createdAt": now_text(),
                "projectRoot": str(PROJECT_ROOT),
            }
            write_json(job_dir / "job.json", job)
            make_status(job_dir, id=job_id, task=task, taskLabel=TASK_LABELS[task], state="queued")

            thread = threading.Thread(target=run_job, args=(job_id, matlab_bin), daemon=True)
            thread.start()
            self.send_json({"job": self.job_payload(job_id)})
        except json.JSONDecodeError:
            self.send_json({"error": "invalid json"}, HTTPStatus.BAD_REQUEST)
        except Exception as exc:
            self.send_json({"error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)

    def handle_job_get(self, path: str) -> None:
        parts = path.strip("/").split("/")
        if len(parts) < 3:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        job_id = parts[2]
        if len(parts) == 4 and parts[3] == "log":
            log_path = RUNS_ROOT / job_id / "stdout.txt"
            self.serve_text_file(log_path, "text/plain; charset=utf-8")
            return
        payload = self.job_payload(job_id)
        if payload is None:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.send_json({"job": payload})

    def stop_job(self, job_id: str) -> None:
        with RUNNING_LOCK:
            proc = RUNNING.get(job_id)
        if proc is None:
            self.send_json({"ok": False, "message": "job is not running"})
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except Exception:
            proc.terminate()
        make_status(RUNS_ROOT / job_id, state="stopping")
        self.send_json({"ok": True})

    def list_jobs(self) -> list[dict[str, Any]]:
        RUNS_ROOT.mkdir(parents=True, exist_ok=True)
        jobs: list[dict[str, Any]] = []
        for path in sorted(RUNS_ROOT.iterdir(), reverse=True):
            if path.is_dir():
                payload = self.job_payload(path.name)
                if payload:
                    jobs.append(payload)
        return jobs[:50]

    def job_payload(self, job_id: str) -> dict[str, Any] | None:
        job_dir = RUNS_ROOT / job_id
        if not job_dir.exists():
            return None
        job = read_json(job_dir / "job.json", {}) or {}
        status = read_json(job_dir / "status.json", {}) or {}
        result = read_json(job_dir / "result.json", None)
        return {
            "id": job_id,
            "task": job.get("task"),
            "taskLabel": job.get("taskLabel"),
            "createdAt": job.get("createdAt"),
            "params": job.get("params", {}),
            "status": status,
            "result": result,
            "artifacts": artifact_list(job_id, job_dir),
        }


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the RM2026 Waves web debugger.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    if not BRIDGE_SCRIPT.exists():
        raise SystemExit(f"missing MATLAB bridge: {BRIDGE_SCRIPT}")
    RUNS_ROOT.mkdir(parents=True, exist_ok=True)
    httpd = ThreadingHTTPServer((args.host, args.port), DebuggerHandler)
    print(f"RM2026 Web Debugger: http://{args.host}:{args.port}")
    print(f"Project root: {PROJECT_ROOT}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("收到停止信号，Web 调试服务退出。")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
