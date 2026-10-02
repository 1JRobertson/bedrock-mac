"""Verify the advertised OS target includes every bundled native component."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('packager', Path(__file__).resolve().parents[1] / 'package-launcher.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackagingTests(unittest.TestCase):
    def test_runtime_dependency_can_raise_minimum_above_python(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ('Python', 'wine'):
                (root / name).write_bytes(b'\xcf\xfa\xed\xfe')
            (root / 'plain.txt').write_text('not a binary')
            def commands(command, **kwargs):
                return 'LC_BUILD_VERSION\n minos ' + ('11.0' if Path(command[-1]).name == 'Python' else '26.0')
            with patch.object(packager.subprocess, 'check_output', side_effect=commands) as read:
                self.assertEqual(packager.minimum_macos(root), '26.0')
            self.assertEqual(read.call_count, 2)

    def test_legacy_load_command_is_included(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'library').write_bytes(b'\xcf\xfa\xed\xfe')
            with patch.object(packager.subprocess, 'check_output', return_value='cmd LC_VERSION_MIN_MACOSX\ncmdsize 16\nversion 16.0\nsdk 26.0'):
                self.assertEqual(packager.minimum_macos(root), '16.0')
