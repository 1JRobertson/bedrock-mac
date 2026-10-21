"""Offline staging boundaries: no downloads, Wine, installed game or accounts."""
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location('mullion_staging_boundaries',
                                                  ROOT / 'experiments/mullion/stage.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MullionStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mullion-staging-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve() / 'experiment'
        self.base.mkdir()
        self.stage = load()
        self.stage.BASE = self.base
        umask = patch.object(self.stage.os, 'umask')
        umask.start()
        self.addCleanup(umask.stop)

    def test_cli_dispatches_staging_through_shared_guard_without_native_work(self):
        with patch.object(sys, 'argv', ['stage.py']), \
                patch.object(self.stage.subprocess, 'call', return_value=75) as guard, \
                patch.object(self.stage, 'stage') as work:
            self.assertEqual(self.stage.main(), 75)
        command = guard.call_args.args[0]
        self.assertEqual(command[:4], [sys.executable, str(self.stage.GUARD), '--log',
                                       str(self.base / 'logs/stage.log')])
        self.assertIn('--worker', command)
        work.assert_not_called()
        self.assertEqual(list(self.base.iterdir()), [])

    def test_linked_log_is_rejected_before_guard_can_open_or_chmod_it(self):
        outside = self.base.parent / 'outside'
        outside.mkdir(mode=0o755)
        (self.base / 'logs').symlink_to(outside, target_is_directory=True)
        before = outside.stat().st_mode
        with patch.object(sys, 'argv', ['stage.py']), \
                patch.object(self.stage.subprocess, 'call') as guard:
            with self.assertRaisesRegex(RuntimeError, 'symlink'):
                self.stage.main()
        guard.assert_not_called()
        self.assertEqual(outside.stat().st_mode, before)
        self.assertEqual(list(outside.iterdir()), [])

    def test_cache_symlink_is_rejected_before_network_or_target_change(self):
        target = self.base.parent / 'preserved'
        target.write_bytes(b'keep')
        cache = self.base / 'cached.zip'
        cache.symlink_to(target)
        with patch.object(self.stage.urllib.request, 'urlopen') as network:
            with self.assertRaisesRegex(RuntimeError, 'symlink'):
                self.stage.download('https://fixture.invalid/archive', cache, 100)
        network.assert_not_called()
        self.assertEqual(target.read_bytes(), b'keep')
        self.assertTrue(cache.is_symlink())

    def test_download_ignores_unrelated_predictable_partial_symlink(self):
        cache = self.base / 'archive.zip'
        target = self.base.parent / 'preserved'
        target.write_bytes(b'keep')
        old_partial = cache.with_suffix('.partial')
        old_partial.symlink_to(target)
        with patch.object(self.stage.urllib.request, 'urlopen', return_value=io.BytesIO(b'payload')):
            self.stage.download('https://fixture.invalid/archive', cache, 100)
        self.assertEqual(cache.read_bytes(), b'payload')
        self.assertEqual(target.read_bytes(), b'keep')
        self.assertTrue(old_partial.is_symlink())
        self.assertEqual(set(self.base.iterdir()), {cache, old_partial})

    def test_failed_download_removes_only_owned_temporary_file(self):
        cache = self.base / 'archive.zip'
        unrelated = cache.with_suffix('.partial')
        unrelated.write_bytes(b'recovery')
        with patch.object(self.stage.urllib.request, 'urlopen', return_value=io.BytesIO(b'too large')):
            with self.assertRaisesRegex(RuntimeError, 'size bound'):
                self.stage.download('https://fixture.invalid/archive', cache, 2)
        self.assertEqual(unrelated.read_bytes(), b'recovery')
        self.assertEqual(list(self.base.iterdir()), [unrelated])

    def test_leaf_output_symlinks_fail_before_any_staging_mutation(self):
        outside = self.base.parent / 'preserved'
        outside.write_bytes(b'keep')
        for relative in ('versions.json', 'dxc/dxcompiler.dll', 'logs/stage.log'):
            with self.subTest(relative=relative):
                path = self.base / relative
                path.parent.mkdir(exist_ok=True)
                path.symlink_to(outside)
                with self.assertRaisesRegex(RuntimeError, 'symlink'):
                    self.stage.safe_paths()
                self.assertEqual(outside.read_bytes(), b'keep')
                path.unlink()

    def test_busy_runtime_stops_stage_before_creating_directories_or_downloading(self):
        with patch.object(self.stage, 'require_idle', side_effect=RuntimeError('live runtime preserved')), \
                patch.object(self.stage, 'download') as download:
            with self.assertRaisesRegex(RuntimeError, 'live runtime'):
                self.stage.stage()
        download.assert_not_called()
        self.assertEqual(list(self.base.iterdir()), [])

    def test_idle_check_only_inspects_experiment_files_and_never_stops_processes(self):
        loader = self.base / 'wine/bin/wine'
        loader.parent.mkdir(parents=True)
        loader.write_bytes(b'fixture')
        for code, error, expected in ((0, '', 'Close the experimental'),
                                      (2, '', 'Cannot verify'), (1, 'permission denied', 'Cannot verify')):
            with self.subTest(code=code), patch.object(self.stage.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([], code, stderr=error)) as inspect:
                with self.assertRaisesRegex(RuntimeError, expected):
                    self.stage.require_idle()
                self.assertEqual(inspect.call_args.args[0], ['/usr/sbin/lsof', '-t', str(loader)])
        with patch.object(self.stage.subprocess, 'run',
                          return_value=subprocess.CompletedProcess([], 1)):
            self.stage.require_idle()
        self.assertEqual(loader.read_bytes(), b'fixture')


if __name__ == '__main__':
    unittest.main()
