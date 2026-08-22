"""独立运行时使用的 UDP 与裁判串口协议。"""

from __future__ import annotations

import struct
from dataclasses import dataclass

from .crc import crc8, crc16

SOF = 0xA5
MAX_REFEREE_DATA_LENGTH = 128

CMD_GAME_STATUS = 0x0001
CMD_ROBOT_STATUS = 0x0201
CMD_RADAR_INFO = 0x020E
CMD_INTERACTIVE = 0x0301
CMD_RADAR_MAP = 0x0305

SUBCMD_RADAR_DECISION = 0x0121
SUBCMD_INFO_ENGINEER = 0x02AA
SUBCMD_INFO_MULTICAST = 0x02AB
SUBCMD_RADAR_SENTRY = 0x0233

SERVER_ID = 0x8080
INFO_MAGIC = b"IF"
INFO_VERSION = 3
INFO_PAYLOAD_LENGTHS = (24, 12, 10, 8, 41)
INFO_CMD_IDS = (0x0A01, 0x0A02, 0x0A03, 0x0A04, 0x0A05)
INFO_PAYLOAD_SIZE = sum(INFO_PAYLOAD_LENGTHS)
INFO_SIZE = 7 + INFO_PAYLOAD_SIZE


@dataclass(frozen=True)
class StatusPacket:
    """发送给 MATLAB 的 3 字节比赛状态。"""

    game_progress: int = 0
    robot_id: int = 0
    own_encrypt_level: int = 0
    is_key_changeable: bool = False

    def pack(self) -> bytes:
        return bytes(
            (
                int(self.game_progress) & 0x0F,
                int(self.robot_id) & 0xFF,
                (int(self.own_encrypt_level) & 0x03)
                | ((1 if self.is_key_changeable else 0) << 2),
            )
        )

    @classmethod
    def unpack(cls, raw: bytes) -> "StatusPacket":
        if len(raw) != 3:
            raise ValueError(f"比赛状态包必须为 3 字节，实际为 {len(raw)}")
        return cls(raw[0] & 0x0F, raw[1], raw[2] & 0x03, bool(raw[2] & 0x04))


@dataclass(frozen=True)
class InfoSnapshot:
    """MATLAB 回传的 InfoMsgBag v3 五命令缓存快照。"""

    valid_mask: int
    fresh_mask: int
    seq: int
    updated_cmd_id: int | None
    payload: bytes
    raw: bytes

    @classmethod
    def unpack(cls, raw: bytes) -> "InfoSnapshot":
        raw = bytes(raw)
        if len(raw) != INFO_SIZE:
            raise ValueError(f"InfoMsgBag v3 必须为 {INFO_SIZE} 字节，实际为 {len(raw)}")
        if raw[:2] != INFO_MAGIC:
            raise ValueError("InfoMsgBag 魔数错误")
        if raw[2] != INFO_VERSION:
            raise ValueError(f"InfoMsgBag 版本必须为 {INFO_VERSION}，实际为 {raw[2]}")
        valid_mask = raw[3] & 0x1F
        update_index = (raw[3] >> 5) & 0x07
        updated = INFO_CMD_IDS[update_index - 1] if 1 <= update_index <= 5 else None
        fresh_mask = raw[4] & 0x1F
        seq = int.from_bytes(raw[5:7], "little")
        payload = raw[7:]
        return cls(valid_mask, fresh_mask, seq, updated, payload, raw)

    def is_valid(self, cmd_id: int) -> bool:
        return cmd_id in INFO_CMD_IDS and bool(self.valid_mask & (1 << INFO_CMD_IDS.index(cmd_id)))

    def is_fresh(self, cmd_id: int) -> bool:
        return cmd_id in INFO_CMD_IDS and bool(self.fresh_mask & (1 << INFO_CMD_IDS.index(cmd_id)))

    def get_payload(self, cmd_id: int) -> bytes:
        if cmd_id not in INFO_CMD_IDS:
            raise ValueError(f"未知信息波命令码：0x{cmd_id:04X}")
        offset = 0
        for current, length in zip(INFO_CMD_IDS, INFO_PAYLOAD_LENGTHS):
            if current == cmd_id:
                return self.payload[offset : offset + length]
            offset += length
        raise AssertionError("命令表不完整")


@dataclass(frozen=True)
class RefereeFrame:
    command_id: int
    data: bytes
    seq: int
    raw: bytes


def pack_referee_frame(command_id: int, data: bytes, seq: int) -> bytes:
    """按官方格式封装一帧；data_length 只计算 data 区。"""
    data = bytes(data)
    if len(data) > MAX_REFEREE_DATA_LENGTH:
        raise ValueError(f"裁判帧 data 过长：{len(data)}")
    header_without_crc = struct.pack("<BHB", SOF, len(data), seq & 0xFF)
    header = header_without_crc + bytes((crc8(header_without_crc),))
    body = header + struct.pack("<H", command_id & 0xFFFF) + data
    return body + struct.pack("<H", crc16(body))


def pack_interactive(subcmd: int, sender: int, receiver: int, user_data: bytes, seq: int) -> bytes:
    user_data = bytes(user_data)
    if len(user_data) > 112:
        raise ValueError(f"交互消息 user_data 超过 112 字节：{len(user_data)}")
    data = struct.pack("<HHH", subcmd, sender, receiver) + user_data
    return pack_referee_frame(CMD_INTERACTIVE, data, seq)


def pack_radar_decision(robot_id: int, key: bytes, seq: int) -> bytes:
    key = bytes(key)
    if len(key) != 7:
        raise ValueError("密钥指令块必须为 7 字节")
    return pack_interactive(SUBCMD_RADAR_DECISION, robot_id, SERVER_ID, b"\x00" + key, seq)


def pack_engineer_info(robot_id: int, user_data: bytes, seq: int) -> bytes:
    receiver = 102 if robot_id >= 100 else 2
    if len(user_data) != 4:
        raise ValueError("0x02AA user_data 必须为 4 字节")
    return pack_interactive(SUBCMD_INFO_ENGINEER, robot_id, receiver, user_data, seq)


def pack_sentry_flags(robot_id: int, flags: int, seq: int) -> bytes:
    receiver = 107 if robot_id >= 100 else 7
    return pack_interactive(SUBCMD_RADAR_SENTRY, robot_id, receiver, bytes((flags & 0xFF,)), seq)


def pack_multicast(robot_id: int, receiver: int, user_data: bytes, seq: int) -> bytes:
    if len(user_data) != 30:
        raise ValueError("0x02AB user_data 必须为 30 字节")
    return pack_interactive(SUBCMD_INFO_MULTICAST, robot_id, receiver, user_data, seq)


def pack_radar_map(coordinates: list[int] | tuple[int, ...], seq: int) -> bytes:
    if len(coordinates) != 24:
        raise ValueError("0x0305 必须包含 24 个坐标")
    values = [max(0, min(0xFFFF, int(value))) for value in coordinates]
    return pack_referee_frame(CMD_RADAR_MAP, struct.pack("<24H", *values), seq)


class RefereeStreamDecoder:
    """可处理粘包、拆包和 CRC 错误的裁判串口流解析器。"""

    def __init__(self, max_data_length: int = MAX_REFEREE_DATA_LENGTH):
        self.buffer = bytearray()
        self.max_data_length = max_data_length
        self.crc_error_count = 0

    def feed(self, chunk: bytes) -> list[RefereeFrame]:
        self.buffer.extend(chunk)
        frames: list[RefereeFrame] = []
        while True:
            try:
                sof_index = self.buffer.index(SOF)
            except ValueError:
                self.buffer.clear()
                break
            if sof_index:
                del self.buffer[:sof_index]
            if len(self.buffer) < 5:
                break
            header = bytes(self.buffer[:5])
            if crc8(header[:4]) != header[4]:
                del self.buffer[0]
                self.crc_error_count += 1
                continue
            data_length = int.from_bytes(header[1:3], "little")
            if data_length > self.max_data_length:
                del self.buffer[0]
                self.crc_error_count += 1
                continue
            total = 5 + 2 + data_length + 2
            if len(self.buffer) < total:
                break
            raw = bytes(self.buffer[:total])
            if crc16(raw[:-2]) != int.from_bytes(raw[-2:], "little"):
                del self.buffer[0]
                self.crc_error_count += 1
                continue
            del self.buffer[:total]
            command_id = int.from_bytes(raw[5:7], "little")
            frames.append(RefereeFrame(command_id, raw[7:-2], raw[3], raw))
        return frames
