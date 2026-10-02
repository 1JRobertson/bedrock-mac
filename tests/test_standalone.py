"""Isolation checks for the standalone launcher; no running game is touched."""
import importlib.util
import os
from pathlib import Path
import socket
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

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

    def test_damaged_setup_record_is_repairable(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            (prefix / '.bedrock-setup.json').write_text('{interrupted')
            with patch.object(standalone, 'PREFIX', prefix):
                self.assertFalse(standalone.setup_matches({'setup_version': 2}))

    def test_account_timeout_stops_owned_helper_and_preserves_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / 'helper'
            helper.touch()
            child = unittest.mock.Mock(pid=43210)
            child.poll.return_value = None
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'HELPER', helper), \
                    patch.object(standalone, 'STATE', root / 'state.json'), \
                    patch.object(standalone, 'account_ready', return_value=False), \
                    patch.object(standalone, 'account_pid', side_effect=[None, 43210]), \
                    patch.object(standalone.subprocess, 'Popen', return_value=child), \
                    patch.object(standalone.time, 'monotonic', side_effect=[0, 2000]):
                with self.assertRaises(standalone.AccountError) as raised:
                    with standalone.account(root / 'game', timeout=10):
                        self.fail('A helper without a ready socket must not launch Minecraft')
                self.assertEqual(raised.exception.code, 'account_timeout')
            child.send_signal.assert_called_once()
            self.assertFalse((root / 'state.json').exists())

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


if __name__ == '__main__':
    unittest.main()
