"""RoboMaster 裁判系统帧使用的 CRC8 与 CRC16。"""

from __future__ import annotations


def crc8(data: bytes | bytearray | memoryview, initial: int = 0xFF) -> int:
    """计算官方 CRC8（反射多项式 0x8C）。"""
    value = initial & 0xFF
    for byte in data:
        value ^= int(byte)
        for _ in range(8):
            value = (value >> 1) ^ (0x8C if value & 1 else 0)
    return value & 0xFF


def crc16(data: bytes | bytearray | memoryview, initial: int = 0xFFFF) -> int:
    """计算官方 CRC16（反射多项式 0x8408）。"""
    value = initial & 0xFFFF
    for byte in data:
        value ^= int(byte)
        for _ in range(8):
            value = (value >> 1) ^ (0x8408 if value & 1 else 0)
    return value & 0xFFFF
