from __future__ import annotations

import struct
import unittest

from wave_runtime.protocol import INFO_PAYLOAD_LENGTHS, RefereeFrame
from wave_runtime.state import WaveBusinessState


def make_snapshot(
    payloads: tuple[bytes, bytes, bytes, bytes, bytes],
    *,
    valid_mask: int = 0x1F,
    fresh_mask: int = 0x1F,
    update_index: int = 1,
    seq: int = 1,
) -> bytes:
    for payload, expected in zip(payloads, INFO_PAYLOAD_LENGTHS):
        if len(payload) != expected:
            raise ValueError((len(payload), expected))
    return (
        b"IF\x03"
        + bytes(((valid_mask & 0x1F) | ((update_index & 0x07) << 5), fresh_mask & 0x1F))
        + seq.to_bytes(2, "little")
        + b"".join(payloads)
    )


class StateTests(unittest.TestCase):
    def setUp(self):
        self.state = WaveBusinessState()
        self.state.robot_id = 9
        self.state.game_progress = 4
        self.state.own_encrypt_level = 1

    def test_key_lifecycle_uses_referee_level(self):
        self.assertEqual(self.state.handle_wave_datagram(b"\x02ABCDEF", 1.0), "key")
        self.assertTrue(self.state.key_verify_pending)
        radar_info_level_2 = bytes((2 << 3,))
        self.state.handle_referee_frame(RefereeFrame(0x020E, radar_info_level_2, 0, b""), 2.0)
        self.assertFalse(self.state.key_verify_pending)
        self.assertEqual(self.state.key[0], 0)
        self.assertEqual(self.state.handle_wave_datagram(b"\x02ABCDEF", 2.1), "ignored-key")
        self.assertEqual(self.state.handle_wave_datagram(b"\x02UVWXYZ", 2.2), "key")

    def test_info_is_used_by_formal_messages(self):
        positions = struct.pack("<12H", *range(1, 13))
        health = struct.pack("<6H", 100, 200, 300, 400, 0, 500)
        projectile = struct.pack("<5H", 11, 22, 33, 44, 55)
        economy = struct.pack("<4H", 66, 77, 0, 0)
        buff = bytearray(41)
        buff[3], buff[4], buff[10], buff[11] = 7, 8, 9, 10
        raw = make_snapshot((positions, health, projectile, economy, bytes(buff)))
        self.assertEqual(self.state.handle_wave_datagram(raw, 10.0), "info")
        self.assertEqual(self.state.build_engineer_user_data(), struct.pack("<HH", 44, 66))
        self.assertEqual(self.state.build_sentry_flags(10.0), 0xFF)
        self.assertEqual(self.state.radar_map_coordinates(10.1), list(range(1, 13)) + [0] * 12)
        self.assertIsNone(self.state.radar_map_coordinates(10.3))
        multicast = self.state.build_multicast_user_data()
        self.assertEqual(len(multicast), 30)
        self.assertEqual(multicast[0], 100)
        self.assertEqual(multicast[6], 100)
        self.assertEqual(multicast[7:9], b"\x00\x00")

    def test_sentry_default_and_fresh_rules(self):
        self.assertEqual(self.state.build_sentry_flags(1.0), 0xFD)
        payloads = (bytes(24), bytes(12), bytes(10), bytes(8), bytes(41))
        raw = make_snapshot(payloads, valid_mask=0x1F, fresh_mask=0, update_index=0)
        self.state.handle_wave_datagram(raw, 2.0)
        self.assertEqual(self.state.build_sentry_flags(2.0), 0xFD)

    def test_info_v3_heartbeat_does_not_refresh_position(self):
        first_positions = struct.pack("<12H", *range(1, 13))
        empty_payloads = (first_positions, bytes(12), bytes(10), bytes(8), bytes(41))
        self.state.handle_wave_datagram(make_snapshot(empty_payloads, update_index=1, seq=10), 1.0)
        self.assertIsNotNone(self.state.radar_map_coordinates(1.1))

        changed_positions = struct.pack("<12H", *range(21, 33))
        heartbeat_payloads = (changed_positions, bytes(12), bytes(10), bytes(8), bytes(41))
        self.state.handle_wave_datagram(make_snapshot(heartbeat_payloads, update_index=0, seq=10), 1.2)
        self.assertIsNone(self.state.radar_map_coordinates(1.3))

    def test_new_match_resets_cache(self):
        self.state.key = b"\x02ABCDEF"
        self.state.key_verify_pending = True
        self.state.game_progress = 3
        self.state.handle_referee_frame(RefereeFrame(0x0001, bytes((0x40, 1, 0)), 0, b""), 5.0)
        self.assertEqual(self.state.game_progress, 4)
        self.assertFalse(self.state.key_verify_pending)
        self.assertIsNone(self.state.info_snapshot)


if __name__ == "__main__":
    unittest.main()
