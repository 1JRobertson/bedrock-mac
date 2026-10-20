"""Atomic live setting writes and post-exit-only capture decoding, using fake files."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('frame_control', ROOT / 'standalone-bedrock-frame-control.py')
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


def fixture():
    data = bytearray(control.SIZE)
    header = [control.MAGIC, 1, control.SIZE, 0, 0, 4, 3, 1, 3, 0, 2, 0, 4096, 65536, 3, 1]
    struct.pack_into('<16Q', data, 0, *header)
    struct.pack_into('<7Q', data, 128, 12, 10, 5280, 2, 3, 2, 0)
    struct.pack_into('<7Q', data, 256, 9, 7, 3696, 2, 2, 1, 0)
    return bytes(data)


class FrameControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.path = self.root / 'control.bin'
        self.path.write_bytes(fixture())

    def test_decodes_complete_capture(self):
        with patch.object(control, 'require_closed') as closed:
            result = control.decode(self.path)
        closed.assert_called_once_with(self.path)
        self.assertEqual(result['totals']['calls'], 21)
        self.assertEqual(result['totals']['hits'], 17)
        self.assertEqual(result['totals']['bytes'], 8976)
        self.assertEqual(result['memory']['sum_pool_peak_bytes'], 65536)
        self.assertEqual(result['memory']['maximum_reserved_bytes'], 384 * 1024 * 1024)
        self.assertTrue(result['decoded_after_exit'])

    def test_refuses_live_capture_and_uncertain_process_check(self):
        for answer in (subprocess.CompletedProcess([], 0, 'p123\n', ''),
                       subprocess.CompletedProcess([], 2, '', 'failure')):
            with patch.object(control.shutil, 'which', return_value='/usr/sbin/lsof'), \
                 patch.object(control.subprocess, 'run', return_value=answer), \
                 self.assertRaises(RuntimeError):
                control.decode(self.path)

    def test_requires_initialized_header_before_process_check(self):
        self.path.write_bytes(bytes(control.SIZE))
        with patch.object(control, 'require_closed') as closed, self.assertRaises(RuntimeError):
            control.decode(self.path)
        closed.assert_not_called()

    def test_rejects_counter_corruption_and_reports_incomplete_coverage(self):
        data = bytearray(fixture())
        struct.pack_into('<Q', data, 128, 999)
        self.path.write_bytes(data)
        with patch.object(control, 'require_closed'), self.assertRaisesRegex(RuntimeError, 'Inconsistent'):
            control.decode(self.path)
        data = bytearray(fixture()); struct.pack_into('<Q', data, 11 * 8, 1)
        self.path.write_bytes(data)
        with patch.object(control, 'require_closed'):
            self.assertFalse(control.decode(self.path)['complete_thread_coverage'])

    def test_rejects_symlink_control(self):
        link = self.root / 'link'; link.symlink_to(self.path)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            control.decode(link)

    def test_rejects_invalid_modes_thread_count_and_memory_bound(self):
        for index, value in ((3, 1024), (4, 8192), (10, 513), (12, control.MAX_RESERVED + 1)):
            data = bytearray(fixture()); struct.pack_into('<Q', data, index * 8, value)
            self.path.write_bytes(data)
            with patch.object(control, 'require_closed'), self.assertRaises(RuntimeError):
                control.decode(self.path)

    def test_atomic_writer_changes_only_requested_chunk(self):
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('Native compiler unavailable')
        out = self.root / 'tool'
        with contextlib.redirect_stdout(io.StringIO()):
            control.build(out, compiler)
        original = fixture()
        for chunk in (0, 4, 16, 64, 0):
            control.set_chunk(out, self.path, chunk)
            expected = bytearray(original); struct.pack_into('<Q', expected, 24, chunk * 1024)
            self.assertEqual(self.path.read_bytes(), expected)
        result = subprocess.run([str(out / 'frame-slab-control'), str(self.path), '8'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_bytes(), original)
        # Status must ignore non-atomic thread records, even deliberately invalid ones.
        poisoned = original[:128] + b'\xff' * (control.SIZE - 128)
        self.path.write_bytes(poisoned)
        result = subprocess.run([str(out / 'frame-slab-control'), str(self.path), 'status'],
                                capture_output=True, text=True, check=True)
        status = json.loads(result.stdout)
        self.assertTrue(status['individual_atomic_snapshot'])
        self.assertFalse(status['coherent_snapshot'])
        self.assertEqual(status['frames_registered'], 4)
        self.assertEqual(status['reserved_bytes'], 4096)
        self.assertNotIn('totals', status)
        self.assertEqual(self.path.read_bytes(), poisoned)
        (out / 'frame-slab-control').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'changed'):
            control.set_chunk(out, self.path, 16)


if __name__ == '__main__':
    unittest.main()
