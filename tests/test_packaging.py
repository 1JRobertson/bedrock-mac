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
    def release_runtime(self, root):
        wine, dxmt = root / 'wine', root / 'dxmt'
        wine.mkdir()
        dxmt.mkdir()
        profile = json.loads((packager.ROOT / 'release-runtime-profile.json').read_text())
        graphics = {'source_commit': profile['upstream']['dxmt']['commit'], 'files': {}}
        for name in ('x86_64-windows/d3d11.dll', 'x86_64-windows/dxgi.dll',
                     'x86_64-windows/d3d10core.dll', 'x86_64-windows/winemetal.dll',
                     'x86_64-unix/winemetal.so'):
            data = ('release ' + name).encode()
            graphics['files'][name] = hashlib.sha256(data).hexdigest()
            for path in (dxmt / name, wine / 'lib/wine' / name):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        lock = packager.ROOT / 'native-dependencies.lock.json'
        receipt = {'source_built': True, 'architecture': 'x86_64',
                   'lock_sha256': hashlib.sha256(lock.read_bytes()).hexdigest(),
                   'source_archives': json.loads(lock.read_text())['components'], 'files': {}}
        for name in ('lib/libgnutls.30.dylib', 'lib/libfreetype.6.dylib'):
            path = wine / name
            path.write_bytes(('release ' + name).encode())
            receipt['files'][name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        manifest = {'wine_source_revision': profile['upstream']['winegdk']['commit'],
                    'architecture': 'x86_64', 'native_dependency_manifest': receipt}
        (wine / 'build-manifest.json').write_text(json.dumps(manifest))
        (wine / 'native-dependency-manifest.json').write_text(json.dumps(receipt))
        (dxmt / 'manifest.json').write_text(json.dumps(graphics))
        return wine, dxmt

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

    def test_sdk_version_does_not_raise_minimum(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'wine').write_bytes(b'\xcf\xfa\xed\xfe')
            with patch.object(packager.subprocess, 'check_output', return_value='LC_BUILD_VERSION\n minos 15.0\n sdk 26.0'):
                self.assertEqual(packager.minimum_macos(root), '15.0')

    def test_unknown_native_target_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'wine').write_bytes(b'\xcf\xfa\xed\xfe')
            with patch.object(packager.subprocess, 'check_output', return_value='no load command'):
                with self.assertRaisesRegex(RuntimeError, 'no macOS deployment target'):
                    packager.minimum_macos(root)

    def test_symlink_inventory_rejects_external_and_broken_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            resources = root / 'Resources'
            resources.mkdir()
            (root / 'private').write_text('not for redistribution')
            link = resources / 'library'
            for target in (root / 'private', resources / 'missing'):
                link.symlink_to(target)
                with self.assertRaisesRegex(RuntimeError, 'escapes resources or is broken'):
                    packager.verify_bundle_links(resources)
                link.unlink()
            (resources / 'real').write_text('library')
            link.symlink_to('real')
            packager.verify_bundle_links(resources)

    def test_experimental_runtime_is_rejected_before_packaging(self):
        with tempfile.TemporaryDirectory() as temporary:
            wine, dxmt = self.release_runtime(Path(temporary))
            packager.validate_release_runtime(wine, dxmt)
            for runtime, filename, modification in ((wine, 'build-manifest.json', 'frame_slab'),
                                                    (dxmt, 'manifest.json', 'borrowed_constants'),
                                                    (wine, 'build-manifest.json', 'future_experiment')):
                path = runtime / filename
                original = path.read_text()
                metadata = json.loads(original)
                metadata['local_modifications'] = {modification: {}}
                path.write_text(json.dumps(metadata))
                with self.subTest(modification=modification), self.assertRaisesRegex(RuntimeError, modification):
                    packager.validate_release_runtime(wine, dxmt)
                path.write_text(original)
            for name in ('bedrock-refmove.json', 'frame-pacing.json', 'pending-hud.json',
                         'dxmt-borrowed-constants.json', 'dxmt-pool-adapter.json'):
                marker = wine / name
                marker.write_text('{}')
                with self.subTest(marker=name), self.assertRaisesRegex(RuntimeError, name):
                    packager.validate_release_runtime(wine, dxmt)
                marker.unlink()

    def test_runtime_copies_must_match_graphics_and_dependency_receipts(self):
        with tempfile.TemporaryDirectory() as temporary:
            wine, dxmt = self.release_runtime(Path(temporary))
            for path in (dxmt / 'x86_64-windows/d3d11.dll',
                         wine / 'lib/wine/x86_64-windows/d3d11.dll',
                         wine / 'lib/libgnutls.30.dylib'):
                original = path.read_bytes()
                path.write_bytes(b'unrecorded runtime replacement')
                with self.subTest(path=path), self.assertRaisesRegex(RuntimeError, 'Runtime bytes differ'):
                    packager.validate_release_runtime(wine, dxmt)
                path.write_bytes(original)
            (wine / 'lib/unrecorded.dylib').write_bytes(b'unreviewed dependency')
            with self.assertRaisesRegex(RuntimeError, 'closure differs'):
                packager.validate_release_runtime(wine, dxmt)

    def test_runtime_revision_and_complete_graphics_inventory_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            wine, dxmt = self.release_runtime(Path(temporary))
            path = dxmt / 'manifest.json'
            original = json.loads(path.read_text())
            metadata = dict(original, source_commit='0' * 40)
            path.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(RuntimeError, 'provenance differs'):
                packager.validate_release_runtime(wine, dxmt)
            del original['files']['x86_64-windows/d3d11.dll']
            path.write_text(json.dumps(original))
            with self.assertRaisesRegex(RuntimeError, 'complete release payload'):
                packager.validate_release_runtime(wine, dxmt)

    def test_native_dependency_symlinks_require_recorded_contained_targets(self):
        with tempfile.TemporaryDirectory() as temporary:
            wine, dxmt = self.release_runtime(Path(temporary))
            target = wine / 'lib/libgnutls.30.dylib'
            real = target.with_name('libgnutls.30.1.dylib')
            target.rename(real)
            target.symlink_to(real.name)
            receipt = json.loads((wine / 'native-dependency-manifest.json').read_text())
            receipt['files']['lib/' + real.name] = receipt['files']['lib/libgnutls.30.dylib']
            receipt['files']['lib/libgnutls.30.dylib'] = {'symlink': real.name}
            manifest = json.loads((wine / 'build-manifest.json').read_text())
            manifest['native_dependency_manifest'] = receipt
            (wine / 'build-manifest.json').write_text(json.dumps(manifest))
            (wine / 'native-dependency-manifest.json').write_text(json.dumps(receipt))
            packager.validate_release_runtime(wine, dxmt)
            real.write_bytes(b'unrecorded target bytes')
            with self.assertRaisesRegex(RuntimeError, 'Runtime bytes differ'):
                packager.validate_release_runtime(wine, dxmt)

    def test_game_or_credentials_in_payload_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ('Minecraft.Windows.exe', 'level.dat', 'developer.p12', 'account-v1'):
                p = root / name
                p.write_text('fixture')
                with self.assertRaisesRegex(RuntimeError, 'Private or unapproved payload'):
                    packager.verify_payload_content(root)
                p.unlink()
            (root / 'LICENSE').write_text('required notice')
            packager.verify_payload_content(root)

    def test_source_snapshot_is_unchanged_when_checkout_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'checkout'
            source.mkdir()
            (source / 'LICENSES').mkdir()
            (source / 'LICENSES/notice').write_bytes(b'original notice')
            for name in packager.SOURCE_FILES:
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(('original ' + name).encode())
            captured = root / 'captured'
            with patch.object(packager, 'ROOT', source):
                hashes = packager.snapshot_sources(captured)
            (source / 'standalone.py').write_bytes(b'changed during packaging')
            (source / 'launcher/setup.py').write_bytes(b'changed worker during freeze')
            for name in ('standalone.py', 'launcher/setup.py'):
                self.assertEqual(hashlib.sha256((captured / name).read_bytes()).hexdigest(), hashes[name])
                self.assertNotEqual(hashlib.sha256((source / name).read_bytes()).hexdigest(), hashes[name])
            self.assertTrue(os.access(captured / 'build-launcher.sh', os.X_OK))
