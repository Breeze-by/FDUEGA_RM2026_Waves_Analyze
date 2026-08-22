# Linux 部署与现场检查

## 软件依赖

- 64 位 Linux，推荐 Ubuntu 22.04 或 24.04。
- MATLAB 与 Communications Toolbox。
- Communications Toolbox Support Package for Analog Devices ADALM-Pluto Radio。
- Python 3.10+、`pyserial`。
- `libiio-utils`、`iproute2`、`iputils-ping`。

示例：

```bash
sudo apt update
sudo apt install -y python3 python3-pip libiio-utils iproute2 iputils-ping
python3 -m pip install --user -r requirements.txt
```

MATLAB 内执行 `supportPackageInstaller` 安装 Pluto 支持包。确认以下命令可用：

```bash
matlab -batch "disp(version); rx=sdrrx('Pluto','RadioID','ip:192.168.2.1'); info(rx); release(rx)"
iio_info -u ip:192.168.2.1
iio_info -u ip:192.168.3.1
```

## 网络与 USB

主机在两张 Pluto USB 网卡上分别需要 `192.168.2.x/24`、`192.168.3.x/24` 地址，不能给两块设备配置相同子网地址。运行：

```bash
./scripts/check_pluto_links.sh
sudo ./scripts/apply_pluto_stability.sh
```

稳定性脚本只匹配 `0456:b673`，关闭 Pluto USB autosuspend 并阻止 ModemManager 抢占 ttyACM。

## 裁判串口

建议建立稳定软链接 `/dev/referee`。未指定时程序依次尝试：

```text
/dev/referee
/dev/ttyACM0
/dev/ttyACM1
/dev/ttyACM2
/dev/ttyUSB*
```

自动扫描会根据 pyserial 设备信息排除 Pluto。当前用户需要串口权限：

```bash
sudo usermod -aG dialout "$USER"
```

重新登录后生效。也可在 `config/wave.env` 中设置 `REFEREE_PORT=/dev/ttyACM0`。

## 正式启动前检查

1. 没有 MATLAB、GNU Radio 或 Web 调试进程占用两块 Pluto。
2. `5006/5007/5008/5010/5012` 未被其他进程占用。
3. 两块设备 IP 与 `config/wave.env` 一致。
4. `./run_tests.sh` 通过。
5. 使用 `./start.sh`，不要使用测试程序注入比赛状态。

WSL 的 USB 转发、NetworkManager 和 IIO 行为与正式 Linux 主机不同，不用于比赛验收。
