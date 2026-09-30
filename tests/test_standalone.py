"""Isolation checks for the standalone launcher; no running game is touched."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('standalone', Path(__file__).resolve().parents[1] / 'standalone.py')
standalone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(standalone)


class IsolationTests(unittest.TestCase):
    def test_inherited_runtime_cannot_select_crossover_or_old_prefix(self):
        with patch.dict(os.environ, {'CX_BOTTLE': 'Bedrock-Mac', 'WINEPREFIX': '/old/prefix',
                                     'WINEDLLPATH': '/CrossOver/lib', 'DYLD_LIBRARY_PATH': '/CrossOver/lib'}):
            env = standalone.environment()
        self.assertEqual(env['WINEPREFIX'], str(standalone.PREFIX))
        self.assertEqual(env['WINEDLLPATH'], str(standalone.DXMT))
        self.assertFalse(any(key.startswith(('CX_', 'DYLD_')) for key in env))
        self.assertNotIn('/CrossOver/', ':'.join(env.values()))

    def test_existing_drive_cannot_be_repointed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / 'prefix'
            (prefix / 'dosdevices').mkdir(parents=True)
            first, second = root / 'first', root / 'second'
            first.mkdir()
            second.mkdir()
            with patch.object(standalone, 'PREFIX', prefix):
                standalone.map_drive('g', first)
                standalone.map_drive('g', first)
                with self.assertRaises(RuntimeError):
                    standalone.map_drive('g', second)
            self.assertEqual((prefix / 'dosdevices/g:').resolve(), first.resolve())

    def test_symlink_account_socket_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / 'real.sock'
            link = root / 'link.sock'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(original))
                original.chmod(0o600)
                link.symlink_to(original)
                with patch.object(standalone, 'SOCKET', link):
                    with self.assertRaises(RuntimeError):
                        standalone.account_ready()

    def test_unknown_socket_owner_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'account.sock'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(path))
                path.chmod(0o600)
                with patch.object(standalone, 'SOCKET', path), patch.object(standalone, 'account_pid', return_value=None):
                    with self.assertRaises(RuntimeError):
                        standalone.account_ready()


    def socket_fixture(self, root):
        path = root / 'account.sock'
        state = root / 'session.json'
        state.write_text(json.dumps({'pid': 999999, 'executable': str(standalone.HELPER)}))
        return path, state

    def test_crashed_recorded_helper_socket_is_recovered(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, state = self.socket_fixture(Path(temporary))
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(path))
                path.chmod(0o600)
            with patch.object(standalone, 'SOCKET', path), patch.object(standalone, 'STATE', state), \
                 patch.object(standalone, 'account_pid', return_value=None), \
                 patch.object(standalone.os, 'kill', side_effect=ProcessLookupError):
                standalone.recover_account_socket()
                self.assertFalse(path.exists())

    def test_listening_socket_survives_stale_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, state = self.socket_fixture(Path(temporary))
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(path))
                path.chmod(0o600)
                connection.listen(1)
                with patch.object(standalone, 'SOCKET', path), patch.object(standalone, 'STATE', state), \
                     patch.object(standalone, 'account_pid', return_value=None), \
                     patch.object(standalone.os, 'kill', side_effect=ProcessLookupError):
                    standalone.recover_account_socket()
                    self.assertTrue(path.exists())

    def test_unrecorded_dead_socket_is_not_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'account.sock'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(path))
                path.chmod(0o600)
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'SOCKET', path), \
                 patch.object(standalone, 'STATE', root / 'missing.json'), \
                 patch.object(standalone, 'account_pid', return_value=None):
                standalone.recover_account_socket()
                self.assertTrue(path.exists())



    def test_failed_socket_cleanup_keeps_recovery_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'account.sock'
            path.write_text('preserved endpoint')
            state = root / 'session.json'
            helper = root / 'helper'
            helper.touch()
            process = Mock(pid=999999)
            process.poll.return_value = 0
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'SOCKET', path), \
                 patch.object(standalone, 'STATE', state), patch.object(standalone, 'HELPER', helper), \
                 patch.object(standalone, 'account_ready', side_effect=[False, True]), \
                 patch.object(standalone, 'account_pid', return_value=None), \
                 patch.object(standalone, 'recover_account_socket'), \
                 patch.object(standalone.subprocess, 'Popen', return_value=process):
                with standalone.account(root):
                    pass
            self.assertTrue(path.exists())
            self.assertEqual(json.loads(state.read_text())['pid'], process.pid)



    def test_rebuilt_graphics_requires_matching_libraries_and_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wine, dxmt = root / 'wine', root / 'dxmt'
            installed = wine / 'lib/wine/x86_64-unix'
            installed.mkdir(parents=True)
            (dxmt / 'x86_64-unix').mkdir(parents=True)
            (root / 'patches').mkdir()
            patch_file = root / 'patches/standalone-dxmt-memory-lifetime.patch'
            trace = root / 'standalone-dxmt-display-trace.c'
            patch_file.write_text('reviewed patch')
            trace.write_text('reviewed trace source')
            (dxmt / 'x86_64-unix/winemetal.so').write_bytes(b'upstream')
            (installed / 'winemetal-upstream.so').write_bytes(b'upstream')
            (installed / 'winemetal.so').write_bytes(b'rebuilt bridge')
            metadata = {
                'version': 'v0.80',
                'source_commit': '589adb780354b461645b29999cefaf533594ee99',
                'files': {name: standalone.sha256(installed / name)
                          for name in ('winemetal.so', 'winemetal-upstream.so')},
                'patch_sha256': standalone.sha256(patch_file),
                'trace_source_sha256': standalone.sha256(trace),
            }
            (wine / 'dxmt-unix-bridge.json').write_text(json.dumps(metadata))
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'WINE', wine), \
                 patch.object(standalone, 'DXMT', dxmt):
                standalone.verify_unix_bridge()
                (installed / 'winemetal-upstream.so').write_bytes(b'wrong dependency')
                with self.assertRaises(RuntimeError):
                    standalone.verify_unix_bridge()
                (installed / 'winemetal-upstream.so').write_bytes(b'upstream')
                patch_file.write_text('changed patch awaiting rebuild')
                with self.assertRaises(RuntimeError):
                    standalone.verify_unix_bridge()


if __name__ == '__main__':
    unittest.main()
