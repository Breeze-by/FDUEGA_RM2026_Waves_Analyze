# Web 调试器

启动：

```bash
python3 tool/web_debugger/server.py --host 127.0.0.1 --port 8765
```

浏览器打开：

```text
http://127.0.0.1:8765
```

说明：

- Web 端不会改 `FSK_RRC_ProjectConfig.m`，所有参数通过 MATLAB 函数参数覆盖。
- 运行记录保存在 `tool/web_debugger/runs/`。
- Pluto 发射在 Web 端要求 `TxTimeSec` 为有限值，避免后台 MATLAB 永久占用设备。
- Python 服务仅使用标准库；计算、Pluto 收发和协议解析仍由现有 MATLAB 入口完成。
