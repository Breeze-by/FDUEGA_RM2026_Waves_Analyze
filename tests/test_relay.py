from __future__ import annotations

import unittest

from info_wave_udp_relay import RelayEngine


def snapshot(seq: int, update_index: int = 1, fresh: int = 0x1F) -> bytes:
    return b"IF\x03" + bytes((0x1F | (update_index << 5), fresh)) + seq.to_bytes(2, "little") + bytes(95)


class RelayTests(unittest.TestCase):
    def test_primary_has_priority_and_failover_takes_over(self):
        relay = RelayEngine(primary_timeout_sec=0.5, fresh_timeout_sec=3.0)
        relay.receive("primary", snapshot(1), 0.0)
        relay.receive("failover", snapshot(2), 0.1)
        self.assertEqual(relay.active_source, "primary")
        self.assertEqual(int.from_bytes(relay.output(0.2)[5:7], "little"), 1)
        self.assertEqual(int.from_bytes(relay.output(0.55)[5:7], "little"), 2)
        self.assertEqual(relay.active_source, "failover")
        relay.receive("primary", snapshot(3), 0.8)
        self.assertEqual(relay.active_source, "primary")

    def test_stale_output_clears_fresh_mask(self):
        relay = RelayEngine(fresh_timeout_sec=3.0)
        relay.receive("primary", snapshot(1), 1.0)
        self.assertEqual(relay.output(3.9)[4], 0x1F)
        self.assertEqual(relay.output(4.1)[4], 0)


if __name__ == "__main__":
    unittest.main()
