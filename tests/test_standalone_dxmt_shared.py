"""Profile isolation checks; no compiler, Wine, GPU, or downloads required."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('dxmt_shared', ROOT / 'standalone-dxmt-shared.py')
graphics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(graphics)


def profile(**options):
    values = dict(packed_constants=False, reuse_input_layout=False)
    values.update(options)
    graphics.configure_profile(argparse.Namespace(**values))
    return graphics.OUT.name, [p.name for p in graphics.PATCHES]


class GraphicsProfileTests(unittest.TestCase):
    def tearDown(self):
        profile()

    def test_existing_profiles_keep_their_outputs_and_patches(self):
        shared = ['standalone-dxmt-shared-buffers.patch']
        packed = shared + ['standalone-dxmt-packed-constants.patch']
        layout = packed + ['standalone-dxmt-input-layout-reuse.patch']
        self.assertEqual(profile(), ('dxmt-shared-buffers', shared))
        self.assertEqual(profile(packed_constants=True), ('dxmt-packed-constants', packed))
        self.assertEqual(profile(reuse_input_layout=True), ('dxmt-input-layout-reuse', layout))

    def test_borrow_candidate_inherits_optimizations_and_frame_latency_support(self):
        output, patches = profile(borrow_constant_buffers=True)
        self.assertEqual(output, 'dxmt-borrowed-constants')
        self.assertEqual(patches, [
            'standalone-dxmt-shared-buffers.patch',
            'standalone-dxmt-packed-constants.patch',
            'standalone-dxmt-input-layout-reuse.patch',
            'standalone-dxmt-frame-latency.patch',
            'standalone-dxmt-borrow-constant-buffers.patch',
        ])
        self.assertTrue(all(path.is_file() for path in graphics.PATCHES))
        self.assertEqual(graphics.PATCH.name, patches[-1])

    def test_selecting_existing_profile_after_candidate_does_not_leak_changes(self):
        profile(borrow_constant_buffers=True)
        self.assertEqual(profile(), ('dxmt-shared-buffers', ['standalone-dxmt-shared-buffers.patch']))
        self.assertEqual(graphics.STATUS_NAME, 'dxmt-shared-buffers.json')
        self.assertEqual(graphics.BACKUP_NAME, 'dxmt-shared-backups')
        self.assertEqual(graphics.MODIFICATION_NAME, 'shared_buffers')

    def test_candidate_cannot_be_staged_or_restored_through_existing_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sentinel = root / 'runtime-marker'
            sentinel.write_text('preserve')
            for command in ('stage', 'restore'):
                result = subprocess.run([
                    sys.executable, str(ROOT / 'standalone-dxmt-shared.py'), command,
                    '--wine', str(root), '--dxmt', str(root), '--borrow-constant-buffers',
                ], text=True, capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn('unrecognized arguments: --borrow-constant-buffers', result.stderr)
                self.assertEqual(sentinel.read_text(), 'preserve')
                self.assertEqual(list(root.iterdir()), [sentinel])


class GraphicsRestoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.wine, self.dxmt, self.out = [self.root / name for name in ('wine', 'dxmt', 'out')]
        self.targets = [self.wine / 'lib/wine/x86_64-windows/d3d11.dll', self.dxmt / 'x86_64-windows/d3d11.dll']
        for target in self.targets:
            target.parent.mkdir(parents=True)
            target.write_bytes(b'original')
        self.original_manifest = (json.dumps({'files': {'x86_64-windows/d3d11.dll': graphics.sha(b'original')},
                                             'other': {'preserve': True}}) + '\n').encode()
        (self.dxmt / 'manifest.json').write_bytes(self.original_manifest)
        self.out.mkdir()
        (self.out / 'd3d11.dll').write_bytes(b'candidate')
        (self.out / 'manifest.json').write_text(json.dumps({
            'dll_sha256': graphics.sha(b'candidate'), 'patch_sha256': graphics.sha(graphics.PATCH.read_bytes()),
            'patches_sha256': {p.name: graphics.sha(p.read_bytes()) for p in graphics.PATCHES}}))
        self.args = argparse.Namespace(wine=self.wine, dxmt=self.dxmt)
        self.out_patch = patch.object(graphics, 'OUT', self.out)
        self.out_patch.start(); self.addCleanup(self.out_patch.stop)
        self.process_patch = patch.object(graphics.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', ''))
        self.process_patch.start(); self.addCleanup(self.process_patch.stop)
        graphics.stage(self.args)
        self.status = self.wine / graphics.STATUS_NAME

    def snapshot(self):
        return {str(path.relative_to(self.root)): path.read_bytes() for path in self.root.rglob('*') if path.is_file()}

    def test_restore_preserves_exact_original_manifest(self):
        graphics.stage(self.args, restore=True)
        self.assertEqual((self.dxmt / 'manifest.json').read_bytes(), self.original_manifest)
        self.assertTrue(all(path.read_bytes() == b'original' for path in self.targets))
        self.assertFalse(self.status.exists())

    def test_restore_refuses_newer_manifest_before_any_replacement(self):
        current = json.loads((self.dxmt / 'manifest.json').read_bytes())
        current['newer_data'] = 'preserve'
        (self.dxmt / 'manifest.json').write_text(json.dumps(current))
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, 'manifest changed since staging'):
            graphics.stage(self.args, restore=True)
        self.assertEqual(self.snapshot(), before)

    def test_legacy_journal_reconstructs_only_exact_owned_manifest(self):
        record = json.loads(self.status.read_bytes())
        record.pop('staged_manifest_sha256')
        self.status.write_text(json.dumps(record))
        graphics.stage(self.args, restore=True)
        self.assertEqual((self.dxmt / 'manifest.json').read_bytes(), self.original_manifest)

    def test_partial_stage_with_original_manifest_can_be_restored(self):
        (self.dxmt / 'manifest.json').write_bytes(self.original_manifest)
        graphics.stage(self.args, restore=True)
        self.assertTrue(all(path.read_bytes() == b'original' for path in self.targets))

    def test_missing_manifest_backup_refuses_uncertain_legacy_restore(self):
        record = json.loads(self.status.read_bytes()); record.pop('manifest_backup')
        self.status.write_text(json.dumps(record))
        before = self.snapshot()
        with self.assertRaisesRegex(SystemExit, 'Missing manifest rollback'):
            graphics.stage(self.args, restore=True)
        self.assertEqual(self.snapshot(), before)


class GraphicsSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'; self.source.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        for relative, data in {
            'src/airconv/meson.build': "  subdir('darwin')\n",
            'src/winemetal/meson.build': "  subdir('unix')\n",
            'src/dxmt/meson.build': "before\ndxmt_shaders_ir = original\nremoved\ndxmt_lib = library()\n",
            'source.cpp': 'original\n',
        }.items():
            path = self.source / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(data)
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        commit = self.git('rev-parse', 'HEAD').strip()
        self.patch_path = self.root / 'reviewed.patch'
        self.patch_path.write_text('--- a/source.cpp\n+++ b/source.cpp\n@@ -1 +1 @@\n-original\n+reviewed\n')
        for name, value in (('COMMIT', commit), ('PATCHES', [self.patch_path])):
            item = patch.object(graphics, name, value); item.start(); self.addCleanup(item.stop)
        self.git('apply', str(self.patch_path))
        for relative in ('src/airconv/meson.build', 'src/winemetal/meson.build'):
            (self.source / relative).write_text('# Reuse the pinned native bridge.\n')
        (self.source / 'src/dxmt/meson.build').write_text("before\ndxmt_shaders_header = files('dxmt_command.h')\n\ndxmt_lib = library()\n")
        self.header = b'verified shader header\n'
        (self.source / 'src/dxmt/dxmt_command.h').write_bytes(self.header)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.source), *args], text=True, stderr=subprocess.PIPE)

    def test_accepts_only_reviewed_patch_and_exact_generated_inputs(self):
        identity = graphics.validate_build_source(self.source, self.header)
        self.assertEqual(identity['shader_header_sha256'], graphics.sha(self.header))
        self.assertEqual(self.git('diff', '--cached'), '')

    def test_rejects_actual_build_checkout_with_different_head(self):
        self.git('commit', '--allow-empty', '-qm', 'different revision')
        with self.assertRaisesRegex(SystemExit, 'build-source revision'):
            graphics.validate_build_source(self.source, self.header)

    def test_rejects_unreviewed_tracked_and_untracked_inputs(self):
        source = self.source / 'source.cpp'; source.write_text('reviewed\nextra\n')
        with self.assertRaisesRegex(SystemExit, 'build-source edits'):
            graphics.validate_build_source(self.source, self.header)
        source.write_text('reviewed\n')
        (self.source / 'injected.h').write_text('extra')
        with self.assertRaisesRegex(SystemExit, 'untracked'):
            graphics.validate_build_source(self.source, self.header)

    def test_rejects_changed_generated_input(self):
        (self.source / 'src/airconv/meson.build').write_text('unreviewed\n')
        with self.assertRaisesRegex(SystemExit, 'generated DXMT build input'):
            graphics.validate_build_source(self.source, self.header)


if __name__ == '__main__':
    unittest.main()
