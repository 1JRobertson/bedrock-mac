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

    def test_accepts_nested_baseline_additions_modified_by_later_patch(self):
        # Like issue #18: bootstrap adds GDK files without staging them, then a
        # later patch edits an added file. Their real-index status is expected.
        additions = ('System/HttpStatusTrace.h', 'System/XGameSave.c', 'System/XGameSave.h',
                     'System/XStore.c', 'System/XStore.h', 'Xodus/Unix/store.h')
        with (self.patches / 'base.patch').open('a') as output:
            for name in additions:
                path = 'dlls/xgameruntime/GDKComponent/' + name
                output.write(f'diff --git a/{path} b/{path}\nnew file mode 100644\n'
                             f'--- /dev/null\n+++ b/{path}\n@@ -0,0 +1 @@\n+reviewed addition\n')
                target = self.source / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('reviewed addition\n')
        store = 'dlls/xgameruntime/GDKComponent/System/XStore.c'
        with (self.patches / 'standalone-wine-fixture.patch').open('a') as output:
            output.write(f'--- a/{store}\n+++ b/{store}\n@@ -1 +1 @@\n'
                         '-reviewed addition\n+reviewed follow-up\n')
        (self.source / store).write_text('reviewed follow-up\n')
        before = (self.source / '.git/index').read_bytes()
        untracked = self.git('ls-files', '--others')
        for name in additions:
            self.assertIn('dlls/xgameruntime/GDKComponent/' + name, untracked)
        self.assertEqual(self.verify()['source_revision'], self.revision)
        self.assertEqual((self.source / '.git/index').read_bytes(), before)
        self.assertEqual(self.git('ls-files', '--others'), untracked)
        (self.source / store).write_text('unreviewed edit\n')
        with self.assertRaisesRegex(RuntimeError, 'reviewed patched tree'):
            self.verify()

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
        (self.source / '.DS_Store').write_bytes(b'Finder metadata')
        for name in ('injected.h', 'ignored.h', '.DS_Store.h'):
            with self.subTest(name=name):
                target = self.source / name; target.write_text('injected\n')
                before = (self.source / '.git/index').read_bytes()
                with self.assertRaisesRegex(RuntimeError, 'untracked or ignored') as failure:
                    self.verify()
                self.assertIn(name, str(failure.exception))
                self.assertIn('1 total', str(failure.exception))
                self.assertEqual(target.read_text(), 'injected\n')
                self.assertEqual((self.source / '.git/index').read_bytes(), before)
                target.unlink()

    def test_allows_finder_metadata_without_changing_identity_or_files(self):
        identity = self.verify()
        before = (self.source / '.git/index').read_bytes()
        paths = (self.source / '.DS_Store', self.source / 'nested/.DS_Store')
        for path in paths:
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(b'\x00\x00\x00\x01Bud1 Finder metadata')
        self.assertEqual(self.verify(), identity)
        for path in paths:
            self.assertEqual(path.read_bytes(), b'\x00\x00\x00\x01Bud1 Finder metadata')
        # The verifier also examines ignored files; metadata stays harmless there.
        (self.source / '.git/info/exclude').write_text('.DS_Store\n')
        paths[0].write_bytes(b'updated Finder metadata')
        self.assertEqual(self.verify(), identity)
        self.assertEqual(paths[0].read_bytes(), b'updated Finder metadata')
        self.assertEqual((self.source / '.git/index').read_bytes(), before)

    def test_rejects_symlink_named_like_finder_metadata(self):
        outside = self.root / 'outside-header.h'; outside.write_text('preserve\n')
        (self.source / '.DS_Store').symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, 'untracked or ignored'):
            self.verify()
        self.assertEqual(outside.read_text(), 'preserve\n')

    def test_rejects_source_hidden_in_finder_named_directory(self):
        directory = self.source / '.DS_Store'; directory.mkdir()
        (directory / 'injected.h').write_text('extra compiler input\n')
        with self.assertRaisesRegex(RuntimeError, 'untracked or ignored'):
            self.verify()

    def test_unexpected_input_diagnostic_is_bounded_and_escapes_filenames(self):
        (self.source / '00-line\nfeed.h').write_text('extra\n')
        (self.source / ('01-' + 'x' * 190 + '.h')).write_text('extra\n')
        for number in range(8):
            (self.source / f'02-extra-{number}.h').write_text('extra\n')
        with self.assertRaisesRegex(RuntimeError, 'untracked or ignored') as failure:
            self.verify()
        message = str(failure.exception)
        self.assertIn('10 total; showing first 5', message)
        self.assertIn('00-line\\nfeed.h', message)
        self.assertNotIn('\n', message)
        self.assertNotIn('x' * 161, message)
        self.assertNotIn('02-extra-7.h', message)
        self.assertLess(len(message), 1200)

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
