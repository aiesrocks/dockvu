"""Memory checker thresholds and process-lifetime isolation; no process inspection."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('memory_watch', Path(__file__).resolve().parents[1] / 'scripts/memory_watch.py')
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


def row(hour, size, process='1:launch-a'):
    return {'time': f'2026-09-21T{hour:02}:00:00+07:00', 'footprint_mb': size, 'process': process}


class MemoryWatchTests(unittest.TestCase):
    def test_display_heartbeat(self):
        self.assertEqual(watch.heartbeat_status({'pid': 7, 'last_refresh': 99}, 7, 100), 'responsive')
        self.assertEqual(watch.heartbeat_status({'pid': 7, 'last_refresh': 60}, 7, 100), 'display_stalled')
        self.assertEqual(watch.heartbeat_status({'pid': 6, 'last_refresh': 99}, 7, 100), 'heartbeat_missing')
        self.assertEqual(watch.heartbeat_status({}, 7, 100), 'heartbeat_missing')
        self.assertEqual(watch.heartbeat_status(None, 7, 100), 'heartbeat_missing')

    def test_units(self):
        self.assertEqual(watch.footprint_mb('Physical footprint: 10.1G\n'), 10.1 * 1024)
        self.assertEqual(watch.footprint_mb('Physical footprint: 29.2M\n'), 29.2)
        with self.assertRaises(ValueError):
            watch.footprint_mb('permission denied')

    def test_budget(self):
        self.assertEqual(watch.assess(row(3, 101), []), 'over_budget')
        self.assertEqual(watch.assess(row(3, 100), []), 'within_budget')
        self.assertEqual(watch.assess(row(3, 30), []), 'within_budget')

    def test_growth_and_fluctuation(self):
        self.assertEqual(watch.assess(row(3, 42), [row(0, 30), row(1, 34), row(2, 38)]), 'sustained_growth')
        self.assertEqual(watch.assess(row(3, 42), [row(0, 30), row(1, 40), row(2, 38)]), 'within_budget')
        self.assertEqual(watch.assess(row(3, 32), [row(0, 30), row(1, 31), row(2, 31.5)]), 'within_budget')

    def test_restart_does_not_join_trends(self):
        self.assertEqual(watch.assess(row(3, 42, '1:launch-b'), [row(0, 30), row(1, 34), row(2, 38)]), 'within_budget')


if __name__ == '__main__':
    unittest.main()
