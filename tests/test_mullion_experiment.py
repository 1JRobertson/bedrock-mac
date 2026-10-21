"""Offline boundaries for the opt-in ray experiment; no Wine, account or game."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'experiments/mullion'


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, BASE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MullionExperimentTests(unittest.TestCase):
    def test_current_checkout_paths_do_not_depend_on_installed_data(self):
        with patch.dict(os.environ, {'BEDROCK_HOME': '/unrelated/installed-data',
                                     'BEDROCK_BUNDLE': '/unrelated/application'}):
            with patch.dict(os.environ):
                os.environ.pop('MULLION_CLIENT_ROOT', None)
                runner = load('mullion_current_layout', 'run.py')
                stage = load('mullion_current_stage', 'stage.py')
        for module in (runner, stage):
            self.assertEqual(module.CLIENT, ROOT)
            self.assertEqual(module.CLIENT_SCRIPTS, ROOT / 'client')
            self.assertEqual(module.BASE, BASE)
        self.assertTrue(runner.GUARD.is_file())
        self.assertEqual(runner.PREFIX, BASE / 'prefix')
        self.assertEqual(runner.GAME, BASE / 'game')

    def test_legacy_input_root_does_not_redirect_experiment_writes(self):
        with tempfile.TemporaryDirectory(prefix='mullion input ') as temp:
            legacy = Path(temp).resolve()
            (legacy / 'standalone.py').write_text('# read-only input fixture\n')
            with patch.dict(os.environ, {'MULLION_CLIENT_ROOT': str(legacy)}):
                runner = load('mullion_legacy_layout', 'run.py')
            self.assertEqual(runner.CLIENT_SCRIPTS, legacy)
            self.assertEqual(runner.PREFIX, BASE / 'prefix')
            self.assertEqual(runner.GAME, BASE / 'game')
            self.assertEqual(set(legacy.iterdir()), {legacy / 'standalone.py'})

    def test_memory_override_cannot_launch_a_build_or_probe(self):
        runner = load('mullion_override_scope', 'run.py')
        with patch.object(runner.subprocess, 'call') as launch, patch.object(runner, 'worker') as worker:
            with patch.object(sys, 'argv', ['run.py', 'probe', '--unguarded-game']):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as result:
                        runner.main()
            launch.assert_not_called()
            worker.assert_not_called()
        self.assertEqual(result.exception.code, 2)

    def test_fixture_build_is_relocatable_and_contains_only_test_packs(self):
        with tempfile.TemporaryDirectory(prefix='mullion fixture ') as temp:
            fixture = Path(temp).resolve() / 'fixture'
            shutil.copytree(BASE / 'fixture', fixture, ignore=shutil.ignore_patterns('out', '__pycache__'))
            result = subprocess.run([sys.executable, '-B', str(fixture / 'build_fixture.py')],
                                    cwd=temp, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            with zipfile.ZipFile(fixture / 'out/Mullion-RayProof.mcaddon') as archive:
                names = set(archive.namelist())
                self.assertTrue(all(n.startswith(('Mullion_RayProof_BP/', 'Mullion_RayProof_RP/')) for n in names))
                self.assertIn('Mullion_RayProof_BP/functions/rayproof/soak_stop.mcfunction', names)
                manifest = json.loads(archive.read('Mullion_RayProof_RP/manifest.json'))
                self.assertIn('raytraced', manifest['capabilities'])
                texture = archive.read('Mullion_RayProof_RP/textures/blocks/iron_block.png')
                self.assertEqual(texture[:8], b'\x89PNG\r\n\x1a\n')
            self.assertEqual({p.name for p in Path(temp).iterdir()}, {'fixture'})


if __name__ == '__main__':
    unittest.main()
