"""Offline Wine compiler-input checks; tiny Git fixtures, no Wine or builds."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wine_source', ROOT / 'tools/verify-wine-source.py')
wine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wine)


class WineSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / 'tools').mkdir()
        self.source = self.root / 'source'; self.source.mkdir()
        self.patches = self.root / 'patches'; self.patches.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        (self.source / 'source.c').write_text('original\n')
        (self.source / 'untouched.h').write_text('reviewed original header\n')
        (self.source / '.gitignore').write_text('ignored.h\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'upstream fixture')
        self.revision = self.git('rev-parse', 'HEAD').strip()
        (self.root / 'tools/bootstrap-sources.py').write_text('PROJECTS = ' + repr({'winegdk': {
            'commit': self.revision, 'patches': ('base.patch',), 'url': 'https://example.invalid/wine'}}) + '\n')
        (self.patches / 'base.patch').write_text('--- a/source.c\n+++ b/source.c\n@@ -1 +1 @@\n-original\n+baseline\n')
        (self.patches / 'standalone-wine-fixture.patch').write_text(
            '--- a/source.c\n+++ b/source.c\n@@ -1 +1 @@\n-baseline\n+standalone\n'
            '--- /dev/null\n+++ b/new-header.h\n@@ -0,0 +1 @@\n+reviewed added header\n')
        self.git('apply', str(self.patches / 'base.patch'))
        self.git('apply', str(self.patches / 'standalone-wine-fixture.patch'))

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.source), *args], text=True, stderr=subprocess.PIPE)

    def verify(self):
        return wine.verify(self.source, self.root)

    def test_exact_baseline_and_standalone_patches_preserve_real_index(self):
        identity = self.verify()
        self.assertEqual(identity['source_revision'], self.revision)
        self.assertEqual(set(identity['patches']), {'base.patch', 'standalone-wine-fixture.patch'})
        self.assertEqual(self.git('diff', '--cached'), '')
        self.assertEqual((self.source / 'source.c').read_text(), 'standalone\n')

    def test_rejects_different_actual_build_head(self):
        self.git('commit', '--allow-empty', '-qm', 'unreviewed revision')
        with self.assertRaisesRegex(RuntimeError, 'pinned revision'):
            self.verify()

    def test_rejects_extra_tracked_edit_outside_patch_paths(self):
        (self.source / 'untouched.h').write_text('injected\n')
        with self.assertRaisesRegex(RuntimeError, 'reviewed patched tree'):
            self.verify()

    def test_rejects_missing_or_changed_required_patch(self):
        (self.source / 'source.c').write_text('baseline\n')
        with self.assertRaisesRegex(RuntimeError, 'reviewed patched tree'):
            self.verify()

    def test_rejects_untracked_and_ignored_compiler_inputs(self):
        for name in ('injected.h', 'ignored.h'):
            with self.subTest(name=name):
                target = self.source / name; target.write_text('injected\n')
                with self.assertRaisesRegex(RuntimeError, 'untracked or ignored'):
                    self.verify()
                target.unlink()

    def test_rejects_symlink_patch_and_checkout(self):
        target = self.patches / 'base.patch'; saved = target.read_bytes(); target.unlink()
        outside = self.root / 'outside.patch'; outside.write_bytes(saved); target.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, 'regular files'):
            self.verify()
        link = self.root / 'source-link'; link.symlink_to(self.source)
        with self.assertRaisesRegex(RuntimeError, 'symlink parents'):
            wine.verify(link, self.root)

    def test_verifier_does_not_inherit_another_git_directory(self):
        with patch.dict(os.environ, {'GIT_DIR': '/unrelated/missing/git', 'GIT_INDEX_FILE': '/unrelated/missing/index'}):
            self.assertEqual(self.verify()['source_revision'], self.revision)

    def test_builder_checks_before_compile_and_install_and_records_identity(self):
        script = (ROOT / 'tools/build-standalone-wine.sh').read_text()
        initial = script.index('"$ROOT/tools/verify-wine-source.py" --source "$SOURCE" --output')
        compile_at = script.index('make -j"$JOBS"')
        first_recheck = script.index('--check-receipt')
        install_at = script.index('make install')
        final_recheck = script.index('--check-receipt', first_recheck + 1)
        self.assertLess(initial, compile_at)
        self.assertLess(compile_at, first_recheck)
        self.assertLess(first_recheck, install_at)
        self.assertLess(install_at, final_recheck)
        self.assertIn('"source_verification": json.loads', script)


if __name__ == '__main__':
    unittest.main()
