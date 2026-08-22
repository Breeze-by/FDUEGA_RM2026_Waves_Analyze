"""信息波正式比赛状态机与业务数据构造。"""

from __future__ import annotations

import struct
import time
from dataclasses import dataclass, field

from .protocol import (
    CMD_GAME_STATUS,
    CMD_RADAR_INFO,
    CMD_ROBOT_STATUS,
    INFO_CMD_IDS,
    INFO_PAYLOAD_LENGTHS,
    InfoSnapshot,
    RefereeFrame,
    StatusPacket,
)

ACTIVE_GAME_PROGRESS = 4
KEY_IDLE_COMMAND = 0
KEY_VERIFY_COMMAND = 2


@dataclass
class WaveBusinessState:
    """只包含电磁波解析与利用所需的正式比赛状态。"""

    info_fresh_timeout_sec: float = 3.0
    position_timeout_sec: float = 0.25
    game_progress: int = 0
    game_remaining_time: int | None = None
    robot_id: int = 0
    own_encrypt_level: int = 0
    is_key_changeable: bool = False
    key: bytes = b"\x00\x00\x00\x00\x00\x00\x00"
    key_verify_pending: bool = False
    key_verify_level: int | None = None
    blocked_stale_key: bytes | None = None
    info_snapshot: InfoSnapshot | None = None
    info_received_at: float | None = None
    payload_cache: dict[int, bytes] = field(default_factory=dict)
    max_health: list[int] = field(default_factory=lambda: [0, 0, 0, 0, 0])
    position_payload: bytes | None = None
    position_updated_at: float | None = None
    position_last_seq: int | None = None
    info_datagram_count: int = 0
    key_datagram_count: int = 0
    ignored_datagram_count: int = 0
    new_match_count: int = 0

    def __post_init__(self) -> None:
        if not self.payload_cache:
            self.payload_cache = {
                cmd_id: bytes(length)
                for cmd_id, length in zip(INFO_CMD_IDS, INFO_PAYLOAD_LENGTHS)
            }

    @property
    def is_active(self) -> bool:
        return self.game_progress == ACTIVE_GAME_PROGRESS

    @property
    def is_blue(self) -> bool:
        return self.robot_id >= 100

    def status_packet(self) -> StatusPacket:
        return StatusPacket(
            self.game_progress,
            self.robot_id,
            self.own_encrypt_level,
            self.is_key_changeable,
        )

    def handle_referee_frame(self, frame: RefereeFrame, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        data = frame.data
        if frame.command_id == CMD_GAME_STATUS and len(data) >= 3:
            old_progress = self.game_progress
            self.game_progress = (data[0] >> 4) & 0x0F
            self.game_remaining_time = int.from_bytes(data[1:3], "little")
            if old_progress != ACTIVE_GAME_PROGRESS and self.game_progress == ACTIVE_GAME_PROGRESS:
                self.reset_match()
                self.new_match_count += 1
            return
        if frame.command_id == CMD_ROBOT_STATUS and data:
            old_robot_id = self.robot_id
            self.robot_id = data[0]
            if old_robot_id and old_robot_id != self.robot_id:
                self.reset_match()
            return
        if frame.command_id == CMD_RADAR_INFO and data:
            value = data[0]
            old_level = self.own_encrypt_level
            self.own_encrypt_level = (value >> 3) & 0x03
            self.is_key_changeable = bool((value >> 5) & 0x01)
            if old_level != self.own_encrypt_level:
                self._on_encrypt_level_changed(old_level, self.own_encrypt_level)

    def reset_match(self) -> None:
        """新小局清空全部波形业务缓存，不复用上一局结果。"""
        self._stop_key_verification(block_current=False)
        self.blocked_stale_key = None
        self.info_snapshot = None
        self.info_received_at = None
        self.payload_cache = {
            cmd_id: bytes(length)
            for cmd_id, length in zip(INFO_CMD_IDS, INFO_PAYLOAD_LENGTHS)
        }
        self.max_health = [0, 0, 0, 0, 0]
        self.position_payload = None
        self.position_updated_at = None
        self.position_last_seq = None

    def _on_encrypt_level_changed(self, old_level: int, new_level: int) -> None:
        block = self.key_verify_pending and ((old_level, new_level) in ((1, 2), (2, 3)) or new_level >= 3)
        self._stop_key_verification(block_current=block)

    def _stop_key_verification(self, block_current: bool) -> None:
        if block_current and self.key_verify_pending:
            self.blocked_stale_key = self.key[1:7]
        self.key = bytes((KEY_IDLE_COMMAND,)) + bytes(self.key[1:7]).ljust(6, b"\x00")[:6]
        self.key_verify_pending = False
        self.key_verify_level = None

    def handle_wave_datagram(self, payload: bytes, now: float | None = None) -> str:
        """严格按 UDP 到达顺序处理 7 字节密钥包和 102 字节 InfoMsgBag v3。"""
        now = time.monotonic() if now is None else now
        payload = bytes(payload)
        if len(payload) == 7:
            self.key_datagram_count += 1
            return "key" if self._accept_key(payload) else "ignored-key"
        if len(payload) == 102:
            try:
                snapshot = InfoSnapshot.unpack(payload)
            except ValueError:
                self.ignored_datagram_count += 1
                return "invalid-info"
            if not self.is_active:
                self.ignored_datagram_count += 1
                return "inactive-info"
            self._accept_info(snapshot, now)
            self.info_datagram_count += 1
            return "info"
        self.ignored_datagram_count += 1
        return "unknown"

    def _accept_key(self, payload: bytes) -> bool:
        if not self.is_active or self.own_encrypt_level not in (1, 2):
            return False
        if payload[0] != KEY_VERIFY_COMMAND:
            return False
        key_text = payload[1:7]
        if len(key_text) != 6 or not all(0x21 <= byte <= 0x7E for byte in key_text):
            return False
        if self.blocked_stale_key is not None and key_text == self.blocked_stale_key:
            return False
        self.key = bytes((KEY_VERIFY_COMMAND,)) + key_text
        self.key_verify_pending = True
        self.key_verify_level = self.own_encrypt_level
        return True

    def _accept_info(self, snapshot: InfoSnapshot, now: float) -> None:
        self.info_snapshot = snapshot
        self.info_received_at = now
        for cmd_id in INFO_CMD_IDS:
            if snapshot.is_valid(cmd_id):
                self.payload_cache[cmd_id] = bytes(snapshot.get_payload(cmd_id))
        self._update_max_health(self.payload_cache[0x0A02])
        if snapshot.is_valid(0x0A01) and snapshot.updated_cmd_id == 0x0A01:
            payload = bytes(snapshot.get_payload(0x0A01))
            if not self._is_newer_seq(snapshot.seq, self.position_last_seq):
                return
            self.position_payload = payload
            self.position_updated_at = now
            self.position_last_seq = snapshot.seq

    @staticmethod
    def _is_newer_seq(seq: int, previous: int | None) -> bool:
        if previous is None:
            return True
        delta = (int(seq) - int(previous)) & 0xFFFF
        return 0 < delta < 0x8000

    def _update_max_health(self, payload: bytes) -> None:
        if len(payload) < 12:
            return
        for index, offset in enumerate((0, 2, 4, 6, 10)):
            value = int.from_bytes(payload[offset : offset + 2], "little")
            self.max_health[index] = max(self.max_health[index], value)

    def effective_fresh_mask(self, now: float | None = None) -> int:
        now = time.monotonic() if now is None else now
        if self.info_snapshot is None or self.info_received_at is None:
            return 0
        if now - self.info_received_at > self.info_fresh_timeout_sec:
            return 0
        return self.info_snapshot.fresh_mask & 0x1F

    def cmd_valid(self, cmd_id: int) -> bool:
        return self.info_snapshot is not None and self.info_snapshot.is_valid(cmd_id)

    def engineer_data_ready(self) -> bool:
        return self.cmd_valid(0x0A03) or self.cmd_valid(0x0A04)

    def multicast_data_ready(self) -> bool:
        return all(self.cmd_valid(cmd_id) for cmd_id in (0x0A02, 0x0A03, 0x0A05))

    def build_engineer_user_data(self) -> bytes:
        projectile = self.payload_cache[0x0A03]
        economy = self.payload_cache[0x0A04]
        return projectile[6:8] + economy[0:2]

    def build_sentry_flags(self, now: float | None = None) -> int:
        """bit5~7 恒为 1；没有新鲜 0x0A05 时返回 0xFD。"""
        flags = 0xFD
        fresh = bool(self.effective_fresh_mask(now) & (1 << INFO_CMD_IDS.index(0x0A05)))
        payload = self.payload_cache[0x0A05]
        if not (fresh and self.cmd_valid(0x0A05) and len(payload) >= 41):
            return flags
        for bit_index, offset in ((0, 36), (2, 38), (3, 39)):
            if payload[offset] != 0:
                flags &= ~(1 << bit_index)
        if payload[37] == 0:
            flags |= 1 << 1
        else:
            flags &= ~(1 << 1)
        if payload[40] != 0 or payload[35] == 5:
            flags &= ~(1 << 4)
        return flags | 0xE0

    def build_multicast_user_data(self) -> bytes:
        health = self.payload_cache[0x0A02]
        projectile = self.payload_cache[0x0A03]
        buff = self.payload_cache[0x0A05]
        self._update_max_health(health)
        layouts = (
            (0, 0, 3, 4, 36, False, False),
            (2, None, 10, 11, 37, True, False),
            (4, 2, 17, 18, 38, False, False),
            (6, 4, 24, 25, 39, False, False),
            (10, 8, 31, 32, 40, False, True),
        )
        result = bytearray()
        for index, (hp_offset, ammo_offset, defense_offset, negative_offset, status_offset, engineer, sentry) in enumerate(layouts):
            current_hp = int.from_bytes(health[hp_offset : hp_offset + 2], "little")
            maximum = self.max_health[index]
            percentage = min(100, max(0, (current_hp * 100 + maximum // 2) // maximum)) if maximum else 0
            result.append(percentage)
            result.extend(b"\x00\x00" if engineer else projectile[ammo_offset : ammo_offset + 2])
            result.append(buff[defense_offset])
            result.append(buff[negative_offset])
            targetable = buff[status_offset] == 0 and not (sentry and buff[35] == 5)
            result.append(int(targetable))
        return bytes(result)

    def radar_map_coordinates(self, now: float | None = None) -> list[int] | None:
        """0x0A01 新鲜时构造 0x0305；己方坐标未知时保持为 0。"""
        now = time.monotonic() if now is None else now
        if self.position_payload is None or self.position_updated_at is None:
            return None
        if now - self.position_updated_at > self.position_timeout_sec:
            return None
        enemy = list(struct.unpack("<12H", self.position_payload[:24]))
        return enemy + [0] * 12

    def multicast_receivers(self) -> tuple[int, int, int]:
        return (101, 103, 104) if self.is_blue else (1, 3, 4)

    def to_status_dict(self, now: float | None = None) -> dict[str, object]:
        now = time.monotonic() if now is None else now
        return {
            "game_progress": self.game_progress,
            "game_remaining_time": self.game_remaining_time,
            "robot_id": self.robot_id,
            "faction": "blue" if self.is_blue else ("red" if self.robot_id else "unknown"),
            "own_encrypt_level": self.own_encrypt_level,
            "is_key_changeable": self.is_key_changeable,
            "key_verify_pending": self.key_verify_pending,
            "key_text": self.key[1:7].decode("ascii", errors="replace") if self.key_verify_pending else "",
            "info_valid_mask": self.info_snapshot.valid_mask if self.info_snapshot else 0,
            "info_fresh_mask": self.effective_fresh_mask(now),
            "info_seq": self.info_snapshot.seq if self.info_snapshot else 0,
            "position_fresh": self.radar_map_coordinates(now) is not None,
            "info_datagrams": self.info_datagram_count,
            "key_datagrams": self.key_datagram_count,
            "ignored_datagrams": self.ignored_datagram_count,
        }
