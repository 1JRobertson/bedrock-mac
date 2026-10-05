"""Check memory alerts, PID reuse, and monitoring isolation without touching a game."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('monitor', Path(__file__).resolve().parents[1] / 'bedrock-monitor.py')
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    def test_memory_alerts_use_physical_footprint_and_boundaries(self):
        for footprint, expected in ((2 * monitor.GIB, []), (6 * monitor.GIB, ['high-memory']),
                                    (10 * monitor.GIB, ['urgent-memory'])):
            sample = dict(footprint_bytes=footprint, monotonic=0, rss_bytes=20 * monitor.GIB)
            self.assertEqual([kind for kind, _ in monitor.warnings([], sample)], expected)

    def test_startup_growth_is_not_reported_as_a_leak(self):
        history = [dict(monotonic=0, footprint_bytes=monitor.GIB)]
        sample = dict(monotonic=600, session_seconds=600, footprint_bytes=2 * monitor.GIB)
        self.assertEqual(monitor.warnings(history, sample), [])
        sample.update(session_seconds=800)
        self.assertEqual(monitor.warnings(history, sample)[0][0], 'memory-growth')

    def test_reused_pid_is_not_a_monitor_or_diagnostic_target(self):
        with patch.object(monitor, 'usage', return_value={'proc_start_abstime': 200}), \
             patch.object(monitor, 'command') as command:
            self.assertFalse(monitor.monitor_alive({'monitor_pid': 123, 'monitor_birth': 100}))
            command.assert_not_called()

    def test_another_wine_runtime_is_not_monitored(self):
        line = '123 1000 20.0 G:\\Minecraft.Windows.exe'
        measured = dict(proc_start_abstime=100, resident_size=1000, phys_footprint=1000,
                        pageins=0, diskio_bytesread=0, diskio_byteswritten=0)
        with patch.object(monitor, 'command', return_value=line), \
             patch.object(monitor, 'usage', return_value=measured), \
             patch.object(monitor, 'owned_game', return_value=False):
            self.assertEqual(monitor.find_games({}), [])
            # A PID reused by the other runtime must be checked again.
            self.assertEqual(monitor.find_games({(123, 99): {}}), [])

    def test_marker_does_not_attach_to_a_reused_game_pid(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(monitor, 'DATA', Path(temporary)), \
                 patch.object(monitor, 'same_process', return_value=False), \
                 patch.object(monitor, 'system_memory', return_value={}), \
                 patch.object(monitor, 'latest_game_log', return_value=None), \
                 patch.object(monitor.subprocess, 'run') as run:
                report = monitor.capture('freeze', [{'pid': 123, 'birth': 100}])
                self.assertTrue((Path(report) / 'incident.json').is_file())
                run.assert_not_called()

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS libproc process metrics')
    def test_native_footprint_and_birth_can_be_read_for_this_test_process(self):
        measured = monitor.usage(monitor.os.getpid())
        self.assertGreater(measured['phys_footprint'], 0)
        self.assertTrue(monitor.same_process(monitor.os.getpid(), measured['proc_start_abstime']))


if __name__ == '__main__':
    unittest.main()
