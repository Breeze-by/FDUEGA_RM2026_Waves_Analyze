from __future__ import annotations

import unittest

from wave_runtime.crc import crc8, crc16
from wave_runtime.protocol import (
    INFO_PAYLOAD_SIZE,
    INFO_SIZE,
    InfoSnapshot,
    RefereeStreamDecoder,
    StatusPacket,
    pack_interactive,
    pack_referee_frame,
)


class ProtocolTests(unittest.TestCase):
    def test_status_packet_layout(self):
        packet = StatusPacket(4, 109, 2, True)
        self.assertEqual(packet.pack(), bytes((4, 109, 6)))
        self.assertEqual(StatusPacket.unpack(packet.pack()), packet)

    def test_referee_frame_crc_and_stream_recovery(self):
        first = pack_referee_frame(0x020E, b"\x35", 7)
        second = pack_interactive(0x0233, 9, 7, b"\xFD", 8)
        self.assertEqual(first.hex().upper(), "A5010007EB0E0235EC08")
        self.assertEqual(first[4], crc8(first[:4]))
        self.assertEqual(int.from_bytes(first[-2:], "little"), crc16(first[:-2]))
        decoder = RefereeStreamDecoder()
        frames = decoder.feed(b"noise" + first[:4])
        self.assertEqual(frames, [])
        frames = decoder.feed(first[4:] + second)
        self.assertEqual([(item.command_id, item.seq) for item in frames], [(0x020E, 7), (0x0301, 8)])
        self.assertEqual(frames[1].data[-1], 0xFD)

    def test_info_snapshot_v3(self):
        payload = bytes(range(INFO_PAYLOAD_SIZE))
        raw = b"IF\x03" + bytes((0x1F | (1 << 5), 0x11)) + (65535).to_bytes(2, "little") + payload
        self.assertEqual(len(raw), INFO_SIZE)
        snapshot = InfoSnapshot.unpack(raw)
        self.assertEqual(snapshot.updated_cmd_id, 0x0A01)
        self.assertTrue(snapshot.is_valid(0x0A05))
        self.assertTrue(snapshot.is_fresh(0x0A01))
        self.assertEqual(len(snapshot.get_payload(0x0A05)), 41)
        with self.assertRaises(ValueError):
            InfoSnapshot.unpack(raw[:-1])
        with self.assertRaises(ValueError):
            InfoSnapshot.unpack(b"IF\x02" + raw[3:])


if __name__ == "__main__":
    unittest.main()
