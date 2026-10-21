"""Check memory alerts, PID reuse, and monitoring isolation without touching a game."""
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
import sys
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('monitor', Path(__file__).resolve().parents[1] / 'client/bedrock-monitor.py')
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    def test_packaged_data_home_is_independent_of_script_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.dict(os.environ, {'BEDROCK_HOME': temporary}):
                packaged = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(packaged)
            self.assertEqual(packaged.ROOT, Path(temporary))
            self.assertEqual(packaged.DATA, Path(temporary) / 'logs/standalone/monitor')
            self.assertEqual(packaged.WINE, Path(temporary) / 'runtime/standalone/wine')

    def test_runtime_detection_follows_packaged_symlink_without_matching_sibling(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle_wine = root / 'Bedrock for Mac.app/Contents/Resources/runtime/wine'
            bundle_wine.mkdir(parents=True)
            linked_wine = root / 'home/runtime/standalone/wine'
            linked_wine.parent.mkdir(parents=True)
            linked_wine.symlink_to(bundle_wine, target_is_directory=True)
            with patch.object(monitor, 'WINE', linked_wine), \
                 patch.object(monitor, 'command') as command:
                for mapped_root in (bundle_wine, linked_wine):
                    command.return_value = f'p123\nn{mapped_root}/lib/wine/x86_64-unix/ntdll.so'
                    self.assertTrue(monitor.owned_game(123))
                command.return_value = f'p123\nn{bundle_wine}-other/lib/wine/ntdll.so'
                self.assertFalse(monitor.owned_game(123))

    def test_invalid_state_shapes_are_treated_as_missing(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / 'latest.json'
            for value in ('[]', 'null', '1', '"old state"', '{broken'):
                state.write_text(value)
                with patch.object(monitor, 'LATEST', state):
                    self.assertEqual(monitor.read_json(state), {})
                    self.assertFalse(monitor.monitor_alive())

    def test_diagnostic_files_are_private_even_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            previous = os.umask(0)
            try:
                state, samples = root / 'latest.json', root / 'samples.jsonl'
                monitor.atomic_json(state, {'safe': True})
                samples.write_text('')
                samples.chmod(0o644)
                monitor.append_json(samples, {'safe': True})
            finally:
                os.umask(previous)
            for path in (state, samples):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                self.assertEqual(json.loads(path.read_text()), {'safe': True})

    def test_failed_atomic_write_preserves_previous_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / 'latest.json'
            state.write_text('{"previous": true}')
            with self.assertRaises(TypeError):
                monitor.atomic_json(state, {'invalid': object()})
            self.assertEqual(json.loads(state.read_text()), {'previous': True})
            self.assertEqual(list(state.parent.iterdir()), [state])

    def test_play_uses_source_script_with_separate_data_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(monitor, 'ROOT', Path(temporary)), \
                 patch.object(monitor, 'start'), \
                 patch.object(monitor, 'event', return_value={'id': 'fixture'}), \
                 patch.object(monitor.subprocess, 'call', return_value=0) as launch, \
                 patch.object(sys, 'argv', ['bedrock-monitor.py', 'play', '--', '--fixture']):
                previous = os.umask(0o077)
                try:
                    self.assertEqual(monitor.main(), 0)
                finally:
                    os.umask(previous)
            launch.assert_called_once_with(
                [sys.executable, str(monitor.SCRIPTS / 'standalone.py'), 'launch', '--fixture'],
                cwd=Path(temporary))

    def test_status_recovers_from_invalid_state_without_printing_raw_logs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = root / 'latest.json'
            state.write_text('[]')
            (root / 'events.jsonl').write_text('{truncated\n{"kind": "fixture"}\n')
            with patch.object(monitor, 'LATEST', state), patch.object(monitor, 'DATA', root), \
                 patch.object(sys, 'stdout', new_callable=io.StringIO) as output:
                monitor.status()
            self.assertEqual(json.loads(output.getvalue()), {
                'monitor_alive': False, 'recent_events': [{'kind': 'fixture'}]})

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
                report = monitor.capture('freeze', [{'pid': 123, 'birth': 100}], deep=True)
                self.assertTrue((Path(report) / 'incident.json').is_file())
                run.assert_not_called()

    def test_automatic_alert_saves_evidence_without_attaching_to_game(self):
        games = [{'pid': 123, 'birth': 100, 'footprint_bytes': monitor.GIB}]
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(monitor, 'DATA', Path(temporary)), \
                 patch.object(monitor, 'same_process') as same_process, \
                 patch.object(monitor, 'owned_game') as owned_game, \
                 patch.object(monitor, 'system_memory', return_value={'pressure_level': 1}), \
                 patch.object(monitor, 'latest_game_log', return_value='game.log'), \
                 patch.object(monitor.subprocess, 'run') as run:
                report = monitor.capture('memory growth', games)
                evidence = json.loads((Path(report) / 'incident.json').read_text())
                self.assertEqual(evidence['processes'], games)
                self.assertEqual(evidence['system'], {'pressure_level': 1})
                self.assertEqual(evidence['game_log'], 'game.log')
                self.assertEqual(evidence['diagnostic_mode'], 'lightweight')
                self.assertEqual(evidence['diagnostics'], [])
                same_process.assert_not_called()
                owned_game.assert_not_called()
                run.assert_not_called()

    def test_explicit_player_report_still_requests_deep_diagnostics(self):
        games = [{'pid': 123, 'birth': 100}]
        with patch.object(monitor, 'read_json', return_value={'games': games}), \
             patch.object(monitor, 'monitor_alive', return_value=True), \
             patch.object(monitor, 'capture', return_value='incident') as capture, \
             patch.object(monitor, 'event'), patch('builtins.print'):
            monitor.mark('stutter')
            capture.assert_called_once_with('stutter', games, deep=True)

    def test_deep_diagnostics_check_game_ownership_and_keep_incident_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(monitor, 'DATA', Path(temporary)), \
                 patch.object(monitor, 'same_process', return_value=True) as same_process, \
                 patch.object(monitor, 'owned_game', return_value=True) as owned_game, \
                 patch.object(monitor, 'system_memory', return_value={}), \
                 patch.object(monitor, 'latest_game_log', return_value=None), \
                 patch.object(monitor.subprocess, 'run', return_value=monitor.subprocess.CompletedProcess([], 0)) as run:
                previous = os.umask(0)
                try:
                    report = Path(monitor.capture('freeze', [{'pid': 123, 'birth': 100}], deep=True))
                finally:
                    os.umask(previous)
                same_process.assert_called_once_with(123, 100)
                owned_game.assert_called_once_with(123)
                self.assertEqual([call.args[0][0] for call in run.call_args_list],
                                 ['/usr/bin/vmmap', '/usr/bin/sample'])
                self.assertEqual(stat.S_IMODE(report.stat().st_mode), 0o700)
                incident = report / 'incident.json'
                self.assertEqual(stat.S_IMODE(incident.stat().st_mode), 0o600)
                evidence = json.loads(incident.read_text())
                self.assertEqual(evidence['diagnostic_mode'], 'deep')
                self.assertEqual(len(evidence['diagnostics']), 2)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS libproc process metrics')
    def test_native_footprint_and_birth_can_be_read_for_this_test_process(self):
        measured = monitor.usage(monitor.os.getpid())
        self.assertGreater(measured['phys_footprint'], 0)
        self.assertTrue(monitor.same_process(monitor.os.getpid(), measured['proc_start_abstime']))


if __name__ == '__main__':
    unittest.main()
