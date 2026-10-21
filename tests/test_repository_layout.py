"""Exercise the source-only export from an unrelated cwd without touching user data."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('layout_export', ROOT / 'tools/export-source.py')
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class RepositoryLayoutTests(unittest.TestCase):
    def test_exported_entry_points_are_independent_of_cwd_and_installed_data(self):
        with tempfile.TemporaryDirectory(prefix='bedrock layout ') as temporary:
            base = Path(temporary)
            source = base / 'exported source'
            exporter.export_sources(ROOT, source)
            home = base / 'existing app data'
            home.mkdir()
            sentinel = home / 'preserved-world-fixture'
            sentinel.write_bytes(b'leave installed data alone')
            env = dict(os.environ, BEDROCK_HOME=str(home),
                       BEDROCK_BUNDLE=str(base / 'unrelated app'), PYTHONDONTWRITEBYTECODE='1')
            # Every command below is read-only, with no game, Wine or account.
            for relative in ('tools/start.py', 'tools/bootstrap-sources.py',
                             'tools/export-source.py', 'tools/build-native-dependencies.py',
                             'tools/build-release-runtime.py', 'tools/package-launcher.py',
                             'tools/build-dmg.py', 'client/standalone.py',
                             'client/standalone-setup.py', 'client/standalone-gameinput.py'):
                with self.subTest(entry_point=relative):
                    result = subprocess.run([sys.executable, '-B', str(source / relative), '--help'],
                                            cwd=base, env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
            before = {str(p.relative_to(source)) for p in source.rglob('*')}
            result = subprocess.run([sys.executable, '-B', str(source / 'tools/start.py'), '--check'],
                                    cwd=base, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('Setup needed', result.stdout)
            self.assertEqual(before, {str(p.relative_to(source)) for p in source.rglob('*')})
            self.assertEqual(sentinel.read_bytes(), b'leave installed data alone')
            self.assertEqual(set(home.iterdir()), {sentinel})
            self.assertFalse((base / 'unrelated app').exists())

    def test_release_recipe_plan_accepts_relocated_pinned_inputs_without_creating_workspace(self):
        with tempfile.TemporaryDirectory(prefix='bedrock plan ') as temporary:
            workspace = Path(temporary) / 'new workspace'
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'tools/build-release-runtime.py'),
                                     'plan', '--workspace', str(workspace)],
                                    cwd=temporary, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['schema'], 1)
            self.assertFalse(workspace.exists())
