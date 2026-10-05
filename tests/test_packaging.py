"""Verify the advertised OS target includes every bundled native component."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('packager', Path(__file__).resolve().parents[1] / 'package-launcher.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackagingTests(unittest.TestCase):
    def test_signed_bridge_retains_provenance_and_checks_packaged_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wine, dxmt = root / 'wine', root / 'dxmt'
            libraries = wine / 'lib/wine/x86_64-unix'
            libraries.mkdir(parents=True)
            (dxmt / 'x86_64-unix').mkdir(parents=True)
            for name, data in [('winemetal.so', b'bridge'), ('winemetal-upstream.so', b'upstream')]:
                (libraries / name).write_bytes(data)
            (dxmt / 'x86_64-unix/winemetal.so').write_bytes(b'upstream')
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            metadata = {
                'version': 'v0.80',
                'source_commit': '589adb780354b461645b29999cefaf533594ee99',
                'files': {name: digest(libraries / name) for name in ('winemetal.so', 'winemetal-upstream.so')},
                'patch_sha256': digest(packager.ROOT / 'patches/standalone-dxmt-memory-lifetime.patch'),
                'trace_source_sha256': digest(packager.ROOT / 'standalone-dxmt-display-trace.c'),
            }
            (wine / 'dxmt-unix-bridge.json').write_text(json.dumps(metadata))
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(packager.verify_source_bridge(wine, dxmt), metadata)
            resources = root / 'app/Contents/Resources'
            shutil.copytree(wine, resources / 'runtime/wine')
            shutil.copytree(dxmt, resources / 'runtime/dxmt')
            for name in ('patches/standalone-dxmt-memory-lifetime.patch', 'standalone-dxmt-display-trace.c'):
                target = resources / 'scripts' / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(packager.ROOT / name, target)
            packaged_libs = resources / 'runtime/wine/lib/wine/x86_64-unix'
            for name in metadata['files']:
                (packaged_libs / name).write_bytes(('signed ' + name).encode())
            (resources / 'runtime/dxmt/x86_64-unix/winemetal.so').write_bytes(b'signed upstream reference')
            packager.record_packaged_bridge(resources, metadata)
            recorded = json.loads((resources / 'runtime/wine/dxmt-unix-bridge.json').read_text())
            self.assertEqual(recorded['source_files'], metadata['files'])
            spec = importlib.util.spec_from_file_location('bridge_runtime', packager.ROOT / 'standalone.py')
            runtime = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(runtime)
            runtime.ROOT = root / 'player-data-without-sources'
            runtime.WINE = resources / 'runtime/wine'
            runtime.DXMT = resources / 'runtime/dxmt'
            with patch.dict(os.environ, {'BEDROCK_BUNDLE': str(resources)}):
                runtime.verify_unix_bridge()
                (packaged_libs / 'winemetal.so').write_bytes(b'changed after signing')
                with self.assertRaises(RuntimeError):
                    runtime.verify_unix_bridge()

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
