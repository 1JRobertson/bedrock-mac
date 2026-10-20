"""Setup retry and launch isolation using disposable files; no installs or sign-in."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('start', Path(__file__).resolve().parents[1] / 'start.py')
start = importlib.util.module_from_spec(spec)
spec.loader.exec_module(start)


class StartTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='bedrock start ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.root_patch = patch.object(start, 'ROOT', self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)
        for name in ('wine', 'graphics', 'helper'):
            (self.root / (name + '.src')).write_text(name)
        self.calls = []

    def build(self, command, label, log):
        name = command[0]
        self.calls.append(name)
        (self.root / (name + '.out')).write_text(name + '-compiled')

    def step(self, steps, name):
        steps.step(name, name, [[name]], [name + '.src'], [name + '.out'])

    def test_retry_skips_completed_steps_and_runs_failed_step_again(self):
        def fail_helper(command, label, log):
            if command[0] == 'helper':
                raise RuntimeError('interrupted')
            self.build(command, label, log)

        with patch.object(start, 'run', side_effect=fail_helper):
            steps = start.Steps()
            self.step(steps, 'wine')
            self.step(steps, 'graphics')
            with self.assertRaisesRegex(RuntimeError, 'interrupted'):
                self.step(steps, 'helper')
        state = json.loads(steps.path.read_text())
        self.assertEqual(set(state), {'wine', 'graphics'})
        self.calls.clear()
        with patch.object(start, 'run', side_effect=self.build):
            retry = start.Steps()
            for name in ('wine', 'graphics', 'helper'):
                self.step(retry, name)
        self.assertEqual(self.calls, ['helper'])

    def test_changed_input_rebuilds_it_and_downstream_only(self):
        with patch.object(start, 'run', side_effect=self.build):
            steps = start.Steps()
            for name in ('wine', 'graphics', 'helper'):
                self.step(steps, name)
            (self.root / 'graphics.src').write_text('new input')
            self.calls.clear()
            retry = start.Steps()
            for name in ('wine', 'graphics', 'helper'):
                self.step(retry, name)
        self.assertEqual(self.calls, ['graphics', 'helper'])

    def test_damaged_output_invalidates_downstream_even_if_inputs_unchanged(self):
        with patch.object(start, 'run', side_effect=self.build):
            steps = start.Steps()
            for name in ('wine', 'graphics', 'helper'):
                self.step(steps, name)
            (self.root / 'wine.out').write_text('partial replacement')
            self.calls.clear()
            retry = start.Steps()
            for name in ('wine', 'graphics', 'helper'):
                self.step(retry, name)
        self.assertEqual(self.calls, ['wine', 'graphics', 'helper'])

    def test_missing_output_cannot_be_marked_complete(self):
        with patch.object(start, 'run'):
            steps = start.Steps()
            with self.assertRaises(FileNotFoundError):
                self.step(steps, 'wine')
        self.assertNotIn('wine', json.loads(steps.path.read_text()))

    def test_check_never_creates_files_or_runs_setup(self):
        for ready in (False, True):
            with patch.object(start, 'installed', return_value=ready), \
                 patch.object(start, 'run', side_effect=AssertionError('process started')), \
                 patch.object(start, 'setup', side_effect=AssertionError('setup started')):
                self.assertEqual(start.main(['--market', 'US', '--check']), 0 if ready else 1)
        self.assertFalse((self.root / 'runtime').exists())

    def test_second_start_cannot_enter_while_first_is_active(self):
        with start.lock('start.lock'):
            with self.assertRaisesRegex(RuntimeError, 'already running'):
                with start.lock('start.lock'):
                    self.fail('second caller acquired lock')
        with start.lock('start.lock'):
            pass

    def test_fresh_checkout_check_does_not_even_write_python_cache(self):
        source = Path(__file__).resolve().parents[1]
        (self.root / 'standalone.py').write_bytes((source / 'standalone.py').read_bytes())
        before = set(self.root.rglob('*'))
        self.assertEqual(start.main(['--check']), 1)
        self.assertEqual(set(self.root.rglob('*')), before)

    def test_complete_installation_launches_without_installing_tools(self):
        class Launcher:
            @staticmethod
            def game_running():
                return False

        with patch.object(start, 'installed', return_value=True), \
             patch.object(start, 'module', return_value=Launcher), \
             patch.object(start.sys, 'platform', 'darwin'), \
             patch.object(start.platform, 'machine', return_value='arm64'), \
             patch.object(start.platform, 'mac_ver', return_value=('15.3', '', '')), \
             patch.object(start, 'setup', side_effect=AssertionError('unexpected setup')), \
             patch.object(start, 'run') as run, patch.dict(start.os.environ), \
             patch.object(start.os, 'umask'):
            self.assertEqual(start.main(['--market', 'US']), 0)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][-4:], ['play', '--', '--market', 'US'])

    def dependency_inputs(self):
        for name in ('build-native-dependencies.py', 'native-dependencies.lock.json'):
            (self.root / name).write_text(name)

    def test_source_dependencies_build_once_then_verify_outputs_before_reusing(self):
        self.dependency_inputs()
        verified = []

        def verify(prefix):
            verified.append(prefix)
            self.assertEqual((prefix / 'dependency-manifest.json').read_text(), 'verified fixture')

        def build(command, label, log):
            self.calls.append(command)
            destination = Path(command[command.index('--destination') + 1])
            self.assertFalse((self.root / 'runtime').exists())
            (destination / 'prefix').mkdir()
            (destination / 'prefix/dependency-manifest.json').write_text('verified fixture')

        with patch.object(start, 'module', return_value=SimpleNamespace(verify=verify)), \
                patch.object(start, 'run', side_effect=build), \
                patch.dict(os.environ, {'STANDALONE_DEPENDENCY_PREFIX': ''}):
            prefix = start.native_dependencies('/source/python', 12)
            self.assertEqual(start.native_dependencies('/source/python', 12), prefix)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][-2:], ['--jobs', '8'])
        self.assertEqual(verified, [prefix, prefix])

    def test_interrupted_dependency_build_is_preserved_and_retry_uses_fresh_attempt(self):
        self.dependency_inputs()
        attempts = []

        def build(command, label, log):
            attempt = Path(command[command.index('--destination') + 1])
            attempts.append(attempt)
            (attempt / 'prefix').mkdir()
            if len(attempts) == 1:
                (attempt / 'prefix/partial-library').write_bytes(b'keep failed output')
                raise RuntimeError('interrupted build')
            (attempt / 'prefix/dependency-manifest.json').write_text('{}')

        verifier = unittest.mock.Mock()
        with patch.object(start, 'module', return_value=SimpleNamespace(verify=verifier)), \
                patch.object(start, 'run', side_effect=build), \
                patch.dict(os.environ, {'STANDALONE_DEPENDENCY_PREFIX': ''}):
            with self.assertRaisesRegex(RuntimeError, 'interrupted build'):
                start.native_dependencies('/source/python', 2)
            verifier.assert_not_called()
            prefix = start.native_dependencies('/source/python', 2)
        self.assertNotEqual(attempts[0], attempts[1])
        self.assertEqual((attempts[0] / 'prefix/partial-library').read_bytes(), b'keep failed output')
        self.assertEqual(prefix, attempts[1] / 'prefix')
        verifier.assert_called_once_with(prefix)

    def test_explicit_dependency_prefix_is_verified_without_build_or_runtime_changes(self):
        prefix = self.root / 'selected dependency prefix'
        verifier = unittest.mock.Mock()
        with patch.object(start, 'module', return_value=SimpleNamespace(verify=verifier)), \
                patch.object(start, 'run') as run, \
                patch.dict(os.environ, {'STANDALONE_DEPENDENCY_PREFIX': str(prefix)}):
            self.assertEqual(start.native_dependencies('/source/python', 2), prefix)
            verifier.assert_called_once_with(prefix)
            run.assert_not_called()
            verifier.side_effect = ValueError('tampered dependency')
            with self.assertRaisesRegex(ValueError, 'tampered dependency'):
                start.native_dependencies('/source/python', 2)
            run.assert_not_called()
        self.assertFalse((self.root / 'runtime').exists())
        self.assertFalse((self.root / 'build').exists())

    def test_invalid_completed_dependency_prefix_is_preserved_without_rebuilding(self):
        self.dependency_inputs()

        def build(command, label, log):
            destination = Path(command[command.index('--destination') + 1])
            (destination / 'prefix').mkdir()
            (destination / 'prefix/dependency-manifest.json').write_text('{}')

        verifier = unittest.mock.Mock()
        with patch.object(start, 'module', return_value=SimpleNamespace(verify=verifier)), \
                patch.object(start, 'run', side_effect=build) as run, \
                patch.dict(os.environ, {'STANDALONE_DEPENDENCY_PREFIX': ''}):
            prefix = start.native_dependencies('/source/python', 2)
            verifier.side_effect = ValueError('changed library')
            with self.assertRaisesRegex(ValueError, 'changed library'):
                start.native_dependencies('/source/python', 2)
            self.assertEqual(run.call_count, 1)
            self.assertTrue((prefix / 'dependency-manifest.json').exists())

    def test_setup_passes_verified_source_prefix_to_wine_and_tracks_receipt(self):
        prefix = self.root / 'verified dependencies/prefix'
        recorded = []

        class Steps:
            def step(self, *args):
                recorded.append(args)

        bootstrap = SimpleNamespace(PROJECTS={'xodus': {'patches': ('account.patch',)}},
                                    HELPER_INPUTS={'standalone-helper.rs': 'helper', 'standalone-xvd.rs': 'xvd'},
                                    bootstrap=unittest.mock.Mock())
        with patch.object(start, 'run') as run, patch.object(start, 'Steps', Steps), \
                patch.object(start, 'module', return_value=bootstrap), \
                patch.object(start, 'native_dependencies', return_value=prefix) as dependencies, \
                patch.dict(os.environ, {'PATH': '/usr/bin:/bin'}):
            start.setup(2, 'US')
            self.assertTrue(os.environ['PATH'].startswith('/opt/homebrew/opt/python@3.13/libexec/bin:'))
        dependencies.assert_called_once_with('/opt/homebrew/opt/python@3.13/bin/python3.13', 2)
        self.assertEqual(recorded[0][0], 'wine')
        wine_command = recorded[0][2][0]
        self.assertEqual(wine_command[:2], ['/usr/bin/env', 'STANDALONE_DEPENDENCY_PREFIX=' + str(prefix)])
        self.assertIn(str(prefix / 'dependency-manifest.json'), recorded[0][3])
        helper_inputs = next(step[3] for step in recorded if step[0] == 'helper')
        self.assertIn('standalone-xvd.rs', helper_inputs)
        self.assertIn('patches/account.patch', helper_inputs)
        self.assertEqual(run.call_args_list[0].args[0][-1], str(self.root / 'install-build-tools.sh'))

    def test_source_release_includes_start_and_console_authentication(self):
        source = Path(__file__).resolve().parents[1]
        with patch.object(start, 'ROOT', source):
            exporter = start.module('export-source')
        for name in ('Start.command', 'start.py', 'install-build-tools.sh',
                     'tests/test_start.py', 'patches/standalone-wine-xuser-z-device-auth.patch'):
            self.assertIn(name, exporter.ALLOWED_FILES)

    def test_fresh_homebrew_rustup_is_found_in_its_keg_only_path(self):
        source = Path(__file__).resolve().parents[1]
        brew_root = self.root / 'homebrew'
        (brew_root / 'bin').mkdir(parents=True)
        brew = brew_root / 'bin/brew'
        brew.write_text('''#!/bin/bash
if [ "$1" = list ]; then exit 1; fi
printf '%s\\n' "$@" > "$(dirname "$0")/../installed-formulae"
mkdir -p "$(dirname "$0")/../opt/rustup/bin"
printf '#!/bin/sh\\nexit 0\\n' > "$(dirname "$0")/../opt/rustup/bin/rustup"
chmod +x "$(dirname "$0")/../opt/rustup/bin/rustup"
''')
        brew.chmod(0o755)
        script = self.root / 'tools.sh'
        script.write_text((source / 'install-build-tools.sh').read_text()
                          .replace('/opt/homebrew', str(brew_root))
                          .replace('/usr/bin/arch', '/usr/bin/true'))
        result = subprocess.run(['/bin/bash', str(script)],
            env=dict(os.environ, PATH='/usr/bin:/bin', CARGO_HOME=str(self.root / 'cargo')),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((brew_root / 'opt/rustup/bin/rustup').is_file())
        formulae = (brew_root / 'installed-formulae').read_text().splitlines()
        self.assertIn('python@3.13', formulae)
        self.assertIn('pkgconf', formulae)
        self.assertNotIn('gnutls', formulae)
        self.assertNotIn('freetype', formulae)


if __name__ == '__main__':
    unittest.main()
