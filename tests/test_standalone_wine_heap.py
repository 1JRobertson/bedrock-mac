"""Stage/rollback safety checks using temporary fake runtimes, never Wine."""
import argparse
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wine_heap', ROOT / 'experiments/standalone-wine-heap.py')
heap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(heap)


def pe(tag):
    data = bytearray(256)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 128)
    data[64:80] = b'Wine builtin DLL'
    data[128:132] = b'PE\0\0'
    struct.pack_into('<H', data, 132, 0x8664)
    struct.pack_into('<H', data, 152, 0x20b)
    data[-1] = tag
    return bytes(data)


class HeapStageTests(unittest.TestCase):
    def test_source_built_runtime_uses_its_verified_matching_headers(self):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary).resolve()
            files = {}
            for name in ('include/gnutls/gnutls.h', 'include/freetype2/ft2build.h'):
                path = runtime / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'exact dependency header')
                files[name] = {'sha256': heap.sha(path.read_bytes())}
            (runtime / 'native-dependency-manifest.json').write_text(json.dumps(
                {'source_built': True, 'architecture': 'x86_64', 'files': files}))
            flags = heap.dependency_header_flags(runtime)
            self.assertEqual(flags['GNUTLS_CFLAGS'], '-I' + str(runtime / 'include'))
            self.assertEqual(flags['FREETYPE_CFLAGS'], '-I' + str(runtime / 'include/freetype2'))
            self.assertNotIn('/opt/homebrew', str(flags))
            (runtime / 'include/gnutls/gnutls.h').write_bytes(b'wrong version')
            with self.assertRaisesRegex(RuntimeError, 'headers failed verification'):
                heap.dependency_header_flags(runtime)

    def test_invalid_dependency_provenance_never_falls_back_to_host_headers(self):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary)
            marker = runtime / 'native-dependency-manifest.json'
            for value in ('{broken', 'null', '{}'):
                marker.write_text(value)
                with self.assertRaises(RuntimeError):
                    heap.dependency_header_flags(runtime)
            marker.unlink()
            marker.symlink_to(runtime / 'missing-manifest')
            with self.assertRaises(RuntimeError):
                heap.dependency_header_flags(runtime)

    def test_legacy_runtime_retains_existing_header_selection(self):
        with tempfile.TemporaryDirectory() as temporary:
            flags = heap.dependency_header_flags(Path(temporary))
            self.assertEqual(flags['GNUTLS_CFLAGS'], '-I/opt/homebrew/opt/gnutls/include')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        self.runtime, self.out = root / 'runtime', root / 'output'
        self.args = argparse.Namespace(wine=self.runtime)
        self.original, self.candidate = pe(1), pe(2)
        self.metadata = heap.json_bytes({'wine_source_revision': heap.COMMIT, 'wine_version': '11.8',
                                         'architecture': 'x86_64', 'other_modification': {'preserve': True}})
        heap.write(self.runtime / heap.DLL, self.original, 0o755)
        heap.write(self.runtime / heap.UNIX, b'fake Unix module')
        heap.write(self.runtime / 'build-manifest.json', self.metadata, 0o640)
        heap.write(self.out / 'ntdll.dll', self.candidate)
        heap.write(self.out / 'source-inputs.json', heap.json_bytes({}))
        manifest = {'format': 1, 'source_commit': heap.COMMIT, 'heap_source_sha256': heap.HEAP_SHA,
                    'patch_sha256': heap.sha(heap.PATCH.read_bytes()), 'dll_sha256': heap.sha(self.candidate),
                    'source_inputs_sha256': heap.sha(heap.json_bytes({})),
                    'architecture': 'x86_64', 'wine_version': '11.8'}
        heap.write(self.out / 'manifest.json', heap.json_bytes(manifest))
        self.addCleanup(patch.stopall)
        patch.object(heap, 'OUT', self.out).start()
        self.lsof = patch.object(heap.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')).start()

    def test_stage_idempotence_and_exact_restore(self):
        heap.stage(self.args)
        self.assertEqual((self.runtime / heap.DLL).read_bytes(), self.candidate)
        self.assertEqual((self.runtime / heap.UNIX).read_bytes(), b'fake Unix module')
        self.assertIn(str(self.runtime / heap.DLL), self.lsof.call_args.args[0])
        self.assertIn(str(self.runtime / heap.UNIX), self.lsof.call_args.args[0])
        record = (self.runtime / heap.STATUS).read_bytes()
        heap.stage(self.args)
        self.assertEqual((self.runtime / heap.STATUS).read_bytes(), record)
        heap.stage(self.args, restore=True)
        self.assertEqual((self.runtime / heap.DLL).read_bytes(), self.original)
        self.assertEqual((self.runtime / 'build-manifest.json').read_bytes(), self.metadata)
        self.assertEqual((self.runtime / heap.DLL).stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.runtime / 'build-manifest.json').stat().st_mode & 0o777, 0o640)
        self.assertFalse((self.runtime / heap.STATUS).exists())

    def test_active_runtime_is_rejected(self):
        self.lsof.return_value = subprocess.CompletedProcess([], 0, 'p123\nn/module\n', '')
        with self.assertRaisesRegex(RuntimeError, 'Close applications'):
            heap.stage(self.args)
        self.assertEqual((self.runtime / heap.DLL).read_bytes(), self.original)

    def test_incompatible_runtime_is_rejected(self):
        metadata = json.loads(self.metadata)
        metadata['wine_source_revision'] = 'unknown'
        heap.write(self.runtime / 'build-manifest.json', heap.json_bytes(metadata))
        with self.assertRaisesRegex(RuntimeError, 'pinned'):
            heap.stage(self.args)

    def test_changed_dll_is_not_overwritten_on_restore(self):
        heap.stage(self.args)
        heap.write(self.runtime / heap.DLL, pe(3))
        with self.assertRaisesRegex(RuntimeError, 'DLL changed'):
            heap.stage(self.args, restore=True)

    def test_changed_manifest_is_not_overwritten_on_restore(self):
        heap.stage(self.args)
        heap.write(self.runtime / 'build-manifest.json', self.metadata + b'\n')
        with self.assertRaisesRegex(RuntimeError, 'manifest changed'):
            heap.stage(self.args, restore=True)

    def test_partial_stage_can_restore(self):
        heap.stage(self.args)
        heap.write(self.runtime / 'build-manifest.json', self.metadata)
        heap.stage(self.args, restore=True)
        self.assertEqual((self.runtime / heap.DLL).read_bytes(), self.original)

    def test_corrupt_backup_is_rejected(self):
        heap.stage(self.args)
        record = json.loads((self.runtime / heap.STATUS).read_bytes())
        heap.write(self.runtime / record['backup'], b'corrupt')
        with self.assertRaisesRegex(RuntimeError, 'Backup checksum'):
            heap.stage(self.args, restore=True)

    def test_symlink_target_is_rejected(self):
        target = self.runtime / heap.DLL
        real = target.with_name('other.dll')
        target.rename(real)
        target.symlink_to(real.name)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            heap.stage(self.args)


if __name__ == '__main__':
    unittest.main()
