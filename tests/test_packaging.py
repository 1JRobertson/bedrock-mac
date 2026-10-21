"""Verify the advertised OS target includes every bundled native component."""
import importlib.util
import contextlib
import io
import hashlib
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('packager', Path(__file__).resolve().parents[1] / 'tools/package-launcher.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackagingTests(unittest.TestCase):
    def release_runtime(self, root):
        wine, dxmt = root / 'wine', root / 'dxmt'
        wine.mkdir()
        dxmt.mkdir()
        profile = json.loads((packager.ROOT / 'config/release-runtime-profile.json').read_text())
        graphics = {'source_commit': profile['upstream']['dxmt']['commit'], 'files': {}}
        for name in ('x86_64-windows/d3d11.dll', 'x86_64-windows/dxgi.dll',
                     'x86_64-windows/d3d10core.dll', 'x86_64-windows/winemetal.dll',
                     'x86_64-unix/winemetal.so'):
            data = ('release ' + name).encode()
            graphics['files'][name] = hashlib.sha256(data).hexdigest()
            for path in (dxmt / name, wine / 'lib/wine' / name):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        lock = packager.ROOT / 'config/native-dependencies.lock.json'
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
        spec = importlib.util.spec_from_file_location('packaging_picker_fixture', packager.ROOT / 'client/standalone-pickers.py')
        pickers = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(pickers)
        dll = wine / 'lib/wine/x86_64-windows/bedrock-pickers.dll'
        binary = bytearray(256)
        binary[:2], binary[60:64], binary[128:134] = b'MZ', (128).to_bytes(4, 'little'), b'PE\0\0\x64\x86'
        dll.write_bytes(binary)
        picker_receipt = {'version': 1, 'files': {'bedrock-pickers.dll': hashlib.sha256(binary).hexdigest()},
                          'source_sha256': {name: pickers.digest(packager.ROOT / name) for name in pickers.SOURCE_INPUTS}}
        (wine / 'file-pickers-build.json').write_text(json.dumps(picker_receipt))
        return wine, dxmt

    def test_relocated_source_scripts_keep_flat_shipped_entry_points(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            captured, resources = root / 'captured', root / 'resources'
            resources.mkdir()
            for source, _relative in packager.BUNDLED_SCRIPTS + packager.BRIDGE_SOURCES:
                path = captured / source
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(('captured ' + source).encode())
            packager.copy_bundle_scripts(captured, resources, include_bridge=True)
            scripts = resources / 'scripts'
            for source, relative in packager.BUNDLED_SCRIPTS + packager.BRIDGE_SOURCES:
                self.assertEqual((scripts / relative).read_bytes(), (captured / source).read_bytes())
            self.assertTrue((scripts / 'standalone.py').is_file())
            self.assertTrue((scripts / 'standalone-setup.py').is_file())
            self.assertTrue((scripts / 'winrt.reg').is_file())
            self.assertFalse((scripts / 'client').exists())
            self.assertTrue((scripts / 'native/file-pickers/pickers.c').is_file())
            self.assertTrue((scripts / 'native/file-pickers/provenance/build-v1.sh.txt').is_file())
            self.assertTrue((scripts / 'standalone-dxmt-display-trace.c').is_file())

    def test_packaged_legacy_picker_receipt_uses_retained_exact_build_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wine, dxmt = self.release_runtime(root)
            spec = importlib.util.spec_from_file_location('source_picker', packager.ROOT / 'client/standalone-pickers.py')
            pickers = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(pickers)
            path = wine / 'file-pickers-build.json'
            receipt = json.loads(path.read_text())
            receipt['source_sha256'] = {old: pickers.digest(packager.ROOT / source)
                                       for old, source in pickers.LEGACY_SOURCE_INPUTS.items()}
            path.write_text(json.dumps(receipt))
            captured = root / 'captured'
            packager.snapshot_sources(captured)
            packager.validate_release_runtime(wine, dxmt, captured)
            resources = root / 'resources'
            resources.mkdir()
            packager.copy_bundle_scripts(captured, resources)
            spec = importlib.util.spec_from_file_location('shipped_picker', resources / 'scripts/standalone-pickers.py')
            shipped = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(shipped)
            with patch.dict(os.environ, {'BEDROCK_BUNDLE': str(resources)}):
                self.assertEqual(shipped.verify_runtime(wine)['source_sha256'], receipt['source_sha256'])
                (resources / 'scripts/native/file-pickers/provenance/build-v1.sh.txt').write_text('changed build provenance')
                with self.assertRaisesRegex(RuntimeError, 'verification'):
                    shipped.verify_runtime(wine)

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
                'trace_source_sha256': digest(packager.ROOT / 'native/graphics/standalone-dxmt-display-trace.c'),
            }
            (wine / 'dxmt-unix-bridge.json').write_text(json.dumps(metadata))
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(packager.verify_source_bridge(wine, dxmt), metadata)
            resources = root / 'app/Contents/Resources'
            shutil.copytree(wine, resources / 'runtime/wine')
            shutil.copytree(dxmt, resources / 'runtime/dxmt')
            packager.copy_bundle_scripts(packager.ROOT, resources, include_bridge=True)
            packaged_libs = resources / 'runtime/wine/lib/wine/x86_64-unix'
            for name in metadata['files']:
                (packaged_libs / name).write_bytes(('signed ' + name).encode())
            (resources / 'runtime/dxmt/x86_64-unix/winemetal.so').write_bytes(b'signed upstream reference')
            packager.record_packaged_bridge(resources, metadata)
            recorded = json.loads((resources / 'runtime/wine/dxmt-unix-bridge.json').read_text())
            self.assertEqual(recorded['source_files'], metadata['files'])
            spec = importlib.util.spec_from_file_location('bridge_runtime', packager.ROOT / 'client/standalone.py')
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
            (source / 'client/standalone.py').write_bytes(b'changed during packaging')
            (source / 'launcher/setup.py').write_bytes(b'changed worker during freeze')
            for name in ('client/standalone.py', 'launcher/setup.py'):
                self.assertEqual(hashlib.sha256((captured / name).read_bytes()).hexdigest(), hashes[name])
                self.assertNotEqual(hashlib.sha256((source / name).read_bytes()).hexdigest(), hashes[name])
            self.assertTrue(os.access(captured / 'tools/build-launcher.sh', os.X_OK))


class DiskImageTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            'dmg_builder', Path(__file__).resolve().parents[1] / 'tools/build-dmg.py')
        self.builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.builder)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / 'Test.app'
        resources = self.app / 'Contents/Resources'
        resources.mkdir(parents=True)
        (resources / 'payload-sha256.json').write_text('{}')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '0.3.0', 'CFBundleVersion': '6',
            'LSMinimumSystemVersion': '15.0'}))
        self.output = self.root / 'preview.dmg'

    def command(self, command, **kwargs):
        if command[:2] == ['hdiutil', 'create']:
            Path(command[-1]).write_bytes(b'verified image fixture')

    def build(self, command=None):
        arguments = ['tools/build-dmg.py', '--app', str(self.app), '--output', str(self.output)]
        with patch.object(sys, 'argv', arguments), \
                patch.object(self.builder.subprocess, 'run', side_effect=command or self.command), \
                contextlib.redirect_stdout(io.StringIO()):
            self.builder.main()

    def test_verified_image_is_published_with_matching_receipt(self):
        self.build()
        self.assertEqual(self.output.read_bytes(), b'verified image fixture')
        receipt = json.loads(self.output.with_suffix('.dmg.json').read_text())
        self.assertEqual(receipt['sha256'], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertEqual(receipt['bytes'], self.output.stat().st_size)
        self.assertFalse(list(self.root.glob('bedrock-dmg-*')))

    def test_receipt_describes_staged_app_when_source_changes(self):
        original = (self.app / 'Contents/Resources/payload-sha256.json').read_bytes()
        verified_apps = []
        def command(arguments, **kwargs):
            self.command(arguments, **kwargs)
            if arguments[0] == 'codesign':
                verified_apps.append(Path(arguments[-1]))
            if arguments[:2] == ['hdiutil', 'create']:
                (self.app / 'Contents/Resources/payload-sha256.json').write_text('changed source')
        self.build(command)
        receipt = json.loads(self.output.with_suffix('.dmg.json').read_text())
        self.assertEqual(receipt['payload_inventory_sha256'], hashlib.sha256(original).hexdigest())
        self.assertEqual(len(verified_apps), 2)
        self.assertEqual(verified_apps[0], self.app.resolve())
        self.assertNotEqual(verified_apps[1], self.app)

    def test_failed_image_creation_or_verification_leaves_retryable_destination(self):
        for failure in ('create', 'verify'):
            def command(arguments, **kwargs):
                self.command(arguments, **kwargs)
                if arguments[:2] == ['hdiutil', failure]:
                    raise subprocess.CalledProcessError(1, arguments)
            with self.subTest(failure=failure), self.assertRaises(subprocess.CalledProcessError):
                self.build(command)
            self.assertFalse(self.output.exists())
            self.assertFalse(self.output.with_suffix('.dmg.json').exists())
            self.assertFalse(list(self.root.glob('bedrock-dmg-*')))
        self.build()

    def test_output_created_during_build_is_preserved(self):
        def command(arguments, **kwargs):
            self.command(arguments, **kwargs)
            if arguments[:2] == ['hdiutil', 'verify']:
                self.output.write_bytes(b'another build owns this destination')
        with self.assertRaises(FileExistsError):
            self.build(command)
        self.assertEqual(self.output.read_bytes(), b'another build owns this destination')
        self.assertFalse(self.output.with_suffix('.dmg.json').exists())

    def test_image_hash_reads_bounded_chunks(self):
        # Enforce bounded reads with a synthetic stream, without allocating a DMG.
        content = b'fixture' * 200000
        class BoundedStream(io.BytesIO):
            def read(self, size=-1):
                if not 0 < size <= 1024 * 1024:
                    raise AssertionError('Unbounded disk-image read')
                return super().read(size)
        with patch.object(Path, 'open', return_value=BoundedStream(content)):
            actual = self.builder.file_sha256(Path('image.dmg'))
        self.assertEqual(actual, hashlib.sha256(content).hexdigest())
