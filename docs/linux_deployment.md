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

## SDR 硬件兼容性

比赛使用微相 E310 开发板。E310 提供 2T2R 通道，选择该硬件是为了给后续 MIMO 接收开发预留空间；当前代码每块板只使用一个接收通道，不包含 MIMO 合并或波束形成。

部署不限定 E310。ADALM-Pluto 或其他能够运行 Pluto 兼容固件，并满足以下条件的 SDR 均可使用：

- 能通过 libiio 的 `ip:` URI 访问；
- MATLAB `sdrrx('Pluto', ...)` 能创建接收对象；
- 支持代码配置的中心频率、采样率、RF 带宽和增益模式；
- 两块设备能够配置到不同的 USB 网络子网。

## 网络与 USB

两块板必须分别配置为：

| 职责 | 板端地址 | 推荐主机地址 |
|---|---|---|
| 信息波接收板 | `192.168.2.1/24` | `192.168.2.10/24` |
| 干扰波接收板 | `192.168.3.1/24` | `192.168.3.10/24` |

Pluto 兼容固件通常通过设备 U 盘中的 `config.txt` 设置网络。

信息波板：

```ini
[NETWORK]
hostname = pluto-info
ipaddr = 192.168.2.1
ipaddr_host = 192.168.2.10
netmask = 255.255.255.0
```

干扰波板：

```ini
[NETWORK]
hostname = pluto-jammer
ipaddr = 192.168.3.1
ipaddr_host = 192.168.3.10
netmask = 255.255.255.0
```

修改时建议一次只连接一块板，保存后安全弹出并重新上电。不同兼容固件的配置入口可能不同，但最终地址必须与上表一致，不能让两块设备使用同一 IP 或同一 USB 子网。配置后运行：

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
