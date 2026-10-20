"""Offline release reconstruction boundaries; all external processes are mocked."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('release_runtime', Path(__file__).resolve().parents[1] / 'build-release-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class ReleaseRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / 'workspace'
        self.source = self.workspace / 'source'
        self.source.mkdir(parents=True)
        self.locks = self.root / 'locks'
        self.locks.mkdir()
        self.patch_name = 'standalone-wine-fixture.patch'
        self.put(self.source / 'patches' / self.patch_name, b'fixture patch')
        self.upstream = {'winegdk': {'url': 'https://example.invalid/wine.git', 'commit': 'a' * 40}}
        self.put(self.source / 'bootstrap-sources.py', 'PROJECTS = ' + repr(self.upstream) + '\n')
        self.profile = {
            'schema': 1, 'source_files': {
                'patches/' + self.patch_name: runtime.digest(self.source / 'patches' / self.patch_name)},
            'wine_standalone_patches': [self.patch_name], 'upstream': self.upstream,
            'toolchain': {'sha256': 'b' * 64, 'directory': 'fixture-toolchain'},
            'build_python_packages': {'meson': '1.10.0', 'ninja': '1.13.2'},
        }
        self.put(self.source / runtime.PROFILE, json.dumps(self.profile))
        self.inventory()
        self.prefix = self.root / 'dependencies'
        self.dependency_files = ('lib/libgnutls.30.dylib', 'lib/libfreetype.6.dylib',
                                 'include/gnutls/gnutls.h', 'include/freetype2/ft2build.h')
        for relative in self.dependency_files:
            self.put(self.prefix / relative, 'fixture ' + relative)
        self.dependency = {
            'schema': 1, 'source_built': True, 'architecture': 'x86_64',
            'source_archives': [{'url': 'https://example.invalid/source.tar.gz', 'sha256': 'a' * 64}],
            'build_commands': [['fixture-build', '--architecture=x86_64']],
            'tool_versions': {'clang': 'fixture'},
            'files': {name: runtime.digest(self.prefix / name) for name in self.dependency_files},
        }
        self.dependency_receipt()
        self.args = SimpleNamespace(workspace=self.workspace, dependencies=self.prefix,
                                    locks=self.locks, toolchain_archive=None, build_python=None, jobs=2,
                                    owner_thread='fixture-release-owner')
        self.prepared = {'phase': 'prepared', 'build_executed': False,
                         'graphics_validation_executed': False, 'gameplay_validated': False}
        self.stack = contextlib.ExitStack()
        self.run = self.stack.enter_context(patch.object(runtime.subprocess, 'run',
            side_effect=AssertionError('External process forbidden in fixture')))
        self.check_output = self.stack.enter_context(patch.object(runtime.subprocess, 'check_output',
            side_effect=AssertionError('External process forbidden in fixture')))

    def tearDown(self):
        self.stack.close()
        self.temp.cleanup()

    def put(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        return path

    def inventory(self):
        names = ['patches/' + self.patch_name, 'bootstrap-sources.py', runtime.PROFILE]
        self.put(self.source / 'SOURCE-SHA256.txt', ''.join(
            runtime.digest(self.source / name) + '  ' + name + '\n' for name in names))

    def dependency_receipt(self):
        return self.put(self.prefix / 'dependency-manifest.json', json.dumps(self.dependency))

    def snapshot(self, root):
        return {str(path.relative_to(root)): path.read_bytes() for path in root.rglob('*') if path.is_file()}

    def test_plan_does_not_create_workspace_or_modify_source(self):
        before = self.snapshot(self.source)
        output = self.root / 'uncreated'
        with patch.object(runtime, 'ROOT', self.source), \
             patch.object(sys, 'argv', ['builder', 'plan', '--workspace', str(output)]), \
             contextlib.redirect_stdout(io.StringIO()) as printed:
            runtime.main()
        self.assertEqual(json.loads(printed.getvalue()), self.profile)
        self.assertFalse(output.exists())
        self.assertEqual(self.snapshot(self.source), before)
        self.run.assert_not_called()
        self.check_output.assert_not_called()

    def exporter_fixture(self, allowed=True):
        entries = {'build-release-runtime.py', runtime.PROFILE, 'tests/test_release_runtime.py',
                   'build-native-dependencies.py', 'native-dependencies.lock.json'} if allowed else set()
        self.put(self.source / 'export-source.py',
                 'import shutil\nALLOWED_FILES = ' + repr(entries) + '\n'
                 'def export_sources(root, destination):\n    shutil.copytree(root, destination)\n')

    def test_prepare_preserves_source_and_marks_all_execution_gates_pending(self):
        self.exporter_fixture()
        before = self.snapshot(self.source)
        destination = self.root / 'new-workspace'
        with patch.object(runtime, 'ROOT', self.source):
            state = runtime.prepare(destination)
        self.assertEqual(state['phase'], 'prepared')
        for field in ('build_executed', 'graphics_validation_executed', 'gameplay_validated'):
            self.assertIs(state[field], False)
        self.assertEqual(state['source_sha256'], runtime.digest(destination / 'source/SOURCE-SHA256.txt'))
        self.assertEqual(self.snapshot(self.source), before)
        self.assertEqual(runtime.read(destination / runtime.RECEIPT), state)
        self.run.assert_not_called()

    def test_prepare_refuses_existing_workspace_and_missing_export_approval(self):
        self.exporter_fixture()
        before = self.snapshot(self.workspace)
        with patch.object(runtime, 'ROOT', self.source), self.assertRaises(RuntimeError):
            runtime.prepare(self.workspace)
        self.assertEqual(self.snapshot(self.workspace), before)
        self.exporter_fixture(allowed=False)
        destination = self.root / 'unapproved-workspace'
        with patch.object(runtime, 'ROOT', self.source), self.assertRaises(RuntimeError):
            runtime.prepare(destination)
        self.assertFalse(destination.exists())

    def test_profile_rejects_modified_selected_source(self):
        (self.source / 'patches' / self.patch_name).write_bytes(b'changed')
        with self.assertRaises(RuntimeError):
            runtime.verify_profile(self.source)

    def test_profile_rejects_added_or_missing_wine_patch(self):
        extra = self.put(self.source / 'patches/standalone-wine-unreviewed.patch', b'new')
        with self.assertRaises(RuntimeError):
            runtime.verify_profile(self.source)
        extra.unlink()
        (self.source / 'patches' / self.patch_name).unlink()
        with self.assertRaises((RuntimeError, OSError)):
            runtime.verify_profile(self.source)

    def test_profile_rejects_changed_upstream_revision(self):
        changed = {'winegdk': dict(self.upstream['winegdk'], commit='b' * 40)}
        (self.source / 'bootstrap-sources.py').write_text('PROJECTS = ' + repr(changed))
        with self.assertRaises(RuntimeError):
            runtime.verify_profile(self.source)

    def test_source_inventory_rejects_tampered_bytes(self):
        (self.source / 'bootstrap-sources.py').write_text('changed')
        with self.assertRaises(RuntimeError):
            runtime.verify_source_snapshot(self.source)

    def test_source_checks_reject_ancestor_symlink_escape(self):
        original = self.source / 'patches'
        outside = self.root / 'outside-patches'
        original.rename(outside)
        original.symlink_to(outside, target_is_directory=True)
        for verifier in (runtime.verify_profile, runtime.verify_source_snapshot):
            with self.subTest(verifier=verifier.__name__), self.assertRaises(RuntimeError):
                verifier(self.source)

    def test_source_snapshot_rejects_symlink_root(self):
        linked = self.root / 'linked-source'
        linked.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            runtime.verify_source_snapshot(linked)

    def test_manifest_paths_reject_absolute_parent_and_noncanonical_paths(self):
        for name in ('/etc/passwd', '../escape', 'a/../escape', 'a//b', './file', ''):
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                runtime.relative_path(name)

    def test_missing_native_dependencies_fail_closed(self):
        with self.assertRaises(RuntimeError):
            runtime.verify_dependencies(None)
        for name in self.dependency_files:
            path = self.prefix / name
            original = path.read_bytes()
            path.unlink()
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                runtime.verify_dependencies(self.prefix)
            path.write_bytes(original)

    def test_native_provenance_is_required(self):
        for field, value in (('source_built', False), ('architecture', 'arm64'), ('source_archives', []),
                             ('build_commands', []), ('tool_versions', {})):
            original = self.dependency[field]
            self.dependency[field] = value
            self.dependency_receipt()
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                runtime.verify_dependencies(self.prefix)
            self.dependency[field] = original

    def test_source_archive_requires_https_and_hex_digest(self):
        for archive in ({'url': 'http://example.invalid/a', 'sha256': 'a' * 64},
                        {'url': 'https://example.invalid/a', 'sha256': 'z' * 64}):
            self.dependency['source_archives'] = [archive]
            self.dependency_receipt()
            with self.subTest(archive=archive), self.assertRaises(RuntimeError):
                runtime.verify_dependencies(self.prefix)

    def test_native_dependency_bytes_must_match_receipt(self):
        (self.prefix / self.dependency_files[0]).write_bytes(b'tampered')
        with self.assertRaises(RuntimeError):
            runtime.verify_dependencies(self.prefix)

    def test_dependency_ancestor_symlink_escape_is_rejected(self):
        original = self.prefix / 'lib'
        outside = self.root / 'outside-libraries'
        original.rename(outside)
        original.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            runtime.verify_dependencies(self.prefix)

    def test_dependency_symlink_requires_contained_recorded_target_bytes(self):
        name = self.dependency_files[0]
        link = self.prefix / name
        content = link.read_bytes()
        link.unlink()
        target = self.put(self.prefix / 'lib/gnutls-real.dylib', content)
        link.symlink_to(target.name)
        self.dependency['files'][name] = {'symlink': target.name}
        self.dependency_receipt()
        with self.assertRaises(RuntimeError):
            runtime.verify_dependencies(self.prefix)
        self.dependency['files']['lib/' + target.name] = runtime.digest(target)
        receipt = self.dependency_receipt()
        self.assertEqual(runtime.verify_dependencies(self.prefix), runtime.digest(receipt))
        target.write_bytes(b'changed target')
        with self.assertRaises(RuntimeError):
            runtime.verify_dependencies(self.prefix)

    def test_existing_shared_lock_is_preserved(self):
        for name in ('heavy-build', 'interactive'):
            lock = self.locks / name
            lock.mkdir()
            marker = self.put(lock / 'owner.json', '{"owner":"other"}')
            with self.subTest(name=name), self.assertRaises((RuntimeError, FileExistsError)):
                with runtime.slot(self.locks, 'heavy-build'):
                    self.fail('Entered occupied slot')
            self.assertEqual(marker.read_text(), '{"owner":"other"}')
            marker.unlink()
            lock.rmdir()

    def test_own_shared_lock_is_released_on_failure(self):
        with self.assertRaisesRegex(RuntimeError, 'fixture failure'):
            with runtime.slot(self.locks, 'heavy-build'):
                self.assertTrue((self.locks / 'heavy-build/owner.json').is_file())
                raise RuntimeError('fixture failure')
        self.assertEqual(list(self.locks.iterdir()), [])

    def test_replaced_lock_owner_is_preserved(self):
        with runtime.slot(self.locks, 'heavy-build'):
            self.put(self.locks / 'heavy-build/owner.json', '{"owner":"replacement"}')
        self.assertEqual(json.loads((self.locks / 'heavy-build/owner.json').read_text()), {'owner': 'replacement'})

    def test_competing_slot_created_during_acquisition_prevents_work(self):
        mkdir = Path.mkdir
        def raced(path, *args, **kwargs):
            result = mkdir(path, *args, **kwargs)
            if path == self.locks / 'heavy-build':
                mkdir(self.locks / 'interactive')
            return result
        with patch.object(Path, 'mkdir', raced), self.assertRaises(RuntimeError):
            with runtime.slot(self.locks, 'heavy-build'):
                self.fail('Entered during competing acquisition')
        self.assertTrue((self.locks / 'interactive').is_dir())
        self.assertFalse((self.locks / 'heavy-build').exists())

    def test_nonzero_step_writes_failure_receipt_and_stops_later_commands(self):
        def fail(command, **kwargs):
            kwargs['stdout'].write(b'fixture step failed\n')
            return subprocess.CompletedProcess(command, 7)
        self.run.side_effect = fail
        logs = self.root / 'step-logs'
        with self.assertRaises(RuntimeError):
            runtime.run_steps([['fixture-1'], ['must-not-run']], self.source, logs, {})
        self.run.assert_called_once()
        receipt = json.loads((logs / 'steps.json').read_text())
        self.assertEqual(receipt[0]['exit_code'], 7)
        self.assertEqual(receipt[0]['argv'], ['fixture-1'])
        self.assertEqual(receipt[0]['log_sha256'], runtime.digest(logs / '01.log'))
        self.assertFalse((logs / '02.log').exists())

    def test_build_rejects_missing_dependencies_before_any_process(self):
        self.args.dependencies = None
        with self.assertRaises(RuntimeError):
            runtime.build(self.args, self.prepared.copy(), self.profile)
        self.run.assert_not_called()
        self.check_output.assert_not_called()

    def test_builder_integration_must_exist_before_external_steps(self):
        self.put(self.source / 'build-standalone-wine.sh', '#!/bin/sh\n')
        with self.assertRaises(RuntimeError):
            runtime.build(self.args, self.prepared.copy(), self.profile)
        self.run.assert_not_called()
        self.check_output.assert_not_called()

    def test_build_rejects_reused_generated_directory(self):
        (self.source / 'runtime').mkdir()
        with self.assertRaises(RuntimeError):
            runtime.build(self.args, self.prepared.copy(), self.profile)
        self.run.assert_not_called()

    def test_build_phase_does_not_allow_replay_over_prior_result(self):
        for state in ({'phase': 'prepared', 'build_executed': 'false'},
                      {'phase': 'graphics_validated_gameplay_pending', 'build_executed': True}):
            with self.subTest(state=state), self.assertRaises(RuntimeError):
                runtime.build(self.args, state, self.profile)
        self.run.assert_not_called()

    def mocked_build_prerequisites(self, exit_code=0):
        self.put(self.source / 'build-standalone-wine.sh', '# fixture STANDALONE_DEPENDENCY_PREFIX\n')
        self.args.toolchain_archive = self.put(self.root / 'toolchain-fixture.tar', b'archive fixture')
        self.profile['toolchain']['sha256'] = runtime.digest(self.args.toolchain_archive)
        self.args.build_python = self.root / 'build-python'
        self.check_output.side_effect = lambda argv, **_kwargs: self.profile['build_python_packages'][Path(argv[0]).name]
        def run(argv, **kwargs):
            if argv[0] == '/usr/bin/tar':
                self.put(self.workspace / 'toolchain' / self.profile['toolchain']['directory'] /
                         'bin/x86_64-w64-mingw32-clang++', b'fixture compiler')
                return subprocess.CompletedProcess(argv, 0)
            kwargs['stdout'].write(b'fixture build output\n')
            return subprocess.CompletedProcess(argv, exit_code)
        self.run.side_effect = run
        self.stack.enter_context(patch.object(runtime, 'host_tool_evidence', return_value={'sdk': 'fixture'}))

    def test_build_filters_inherited_runtime_redirection_variables(self):
        self.mocked_build_prerequisites()
        dangerous = {'STANDALONE_WINE_RUNTIME': '/fixture-live/runtime',
                     'STANDALONE_WINE_BUILD': '/fixture-live/build',
                     'STANDALONE_WINE_SOURCE': '/fixture-live/source',
                     'WINEPREFIX': '/fixture-live/prefix', 'BEDROCK_HOME': '/fixture-live/home',
                     'CC': '/unreviewed/compiler', 'CXX': '/unreviewed/cxx',
                     'CFLAGS': '-include /unreviewed/header', 'CXXFLAGS': '-DUNREVIEWED=1',
                     'LDFLAGS': '-L/unreviewed/lib', 'CPATH': '/unreviewed/include',
                     'SDKROOT': '/unreviewed/sdk', 'PKG_CONFIG_PATH': '/unreviewed/pkgconfig'}
        with patch.dict(os.environ, dangerous):
            state = runtime.build(self.args, self.prepared.copy(), self.profile)
        for call in self.run.call_args_list:
            if call.args[0][0] == '/usr/bin/tar':
                continue
            env = call.kwargs['env']
            for key in dangerous:
                self.assertFalse(key in env, 'Unexpected inherited override: ' + key)
            self.assertEqual(env['STANDALONE_DEPENDENCY_PREFIX'], str(self.prefix))
            self.assertEqual(env['STANDALONE_JOBS'], '2')
        recorded_env = runtime.read(self.workspace / 'build-environment.json')
        self.assertEqual(recorded_env, env)
        self.assertEqual(state['build_environment_sha256'], runtime.digest(self.workspace / 'build-environment.json'))
        self.assertEqual(state['phase'], 'built_pending_graphics_validation')
        self.assertFalse(state['graphics_validation_executed'])
        self.assertFalse(state['gameplay_validated'])
        self.assertEqual(list(self.locks.iterdir()), [])

    def test_failed_build_records_failed_state_and_step_failure_receipt(self):
        self.mocked_build_prerequisites(exit_code=9)
        state = self.prepared.copy()
        runtime.write(self.workspace / runtime.RECEIPT, state)
        with self.assertRaises(RuntimeError):
            runtime.build(self.args, state, self.profile)
        self.assertEqual(state['phase'], 'build_failed')
        self.assertTrue(state['build_attempted'])
        self.assertFalse(state['build_executed'])
        self.assertFalse(state['graphics_validation_executed'])
        self.assertFalse(state['gameplay_validated'])
        self.assertEqual(runtime.read(self.workspace / runtime.RECEIPT), state)
        steps = json.loads((self.workspace / 'build-logs/steps.json').read_text())
        self.assertEqual(len(steps), 1)
        self.assertEqual(steps[0]['exit_code'], 9)
        self.assertEqual(self.run.call_count, 2)  # Mock extraction plus first build step only.
        self.assertEqual(list(self.locks.iterdir()), [])

    def test_validation_requires_completed_build_phase_and_exact_boolean(self):
        self.check_output.side_effect = None
        self.check_output.return_value = ''
        invalid = [self.prepared.copy(), {'phase': 'prepared', 'build_executed': True},
                   {'phase': 'built_pending_graphics_validation', 'build_executed': 'false'},
                   {'phase': 'built_pending_graphics_validation', 'build_executed': 1}]
        with patch.object(runtime, 'run_steps') as steps:
            for state in invalid:
                with self.subTest(state=state), self.assertRaises(RuntimeError):
                    runtime.validate(self.args, state)
            steps.assert_not_called()
        self.assertFalse((self.workspace / runtime.RECEIPT).exists())

    def built_state(self):
        return dict(self.prepared, phase='built_pending_graphics_validation', build_executed=True)

    def test_graphics_validation_refuses_any_running_game(self):
        self.check_output.side_effect = None
        self.check_output.return_value = 'G:\\Minecraft.Windows.exe\n'
        with patch.object(runtime, 'run_steps') as steps, self.assertRaises(RuntimeError):
            runtime.validate(self.args, self.built_state())
        steps.assert_not_called()
        self.assertEqual(list(self.locks.iterdir()), [])

    def test_graphics_validation_rejects_runtime_symlink_escape(self):
        self.check_output.side_effect = None
        self.check_output.return_value = ''
        outside = self.root / 'live-runtime-fixture'
        outside.mkdir()
        link = self.source / 'runtime'
        link.symlink_to(outside, target_is_directory=True)
        with patch.object(runtime, 'run_steps') as steps, self.assertRaises(RuntimeError):
            runtime.validate(self.args, self.built_state())
        steps.assert_not_called()

    def test_failed_graphics_step_does_not_advance_validation_receipt(self):
        self.check_output.side_effect = None
        self.check_output.return_value = ''
        state = self.built_state()
        runtime.write(self.workspace / runtime.RECEIPT, state)
        with patch.object(runtime, 'run_steps', side_effect=RuntimeError('fixture fail')), self.assertRaises(RuntimeError):
            runtime.validate(self.args, state)
        self.assertEqual(runtime.read(self.workspace / runtime.RECEIPT), state)
        self.assertEqual(state['phase'], 'graphics_validation_failed')
        self.assertFalse(state['graphics_validation_executed'])
        self.assertEqual(list(self.locks.iterdir()), [])

    def test_successful_graphics_phase_still_does_not_claim_gameplay(self):
        self.check_output.side_effect = None
        self.check_output.return_value = ''
        dangerous = {'STANDALONE_WINE_RUNTIME': '/fixture-live/runtime',
                     'WINEPREFIX': '/fixture-live/prefix', 'BEDROCK_HOME': '/fixture-live/home',
                     'CC': '/unreviewed/compiler', 'CXX': '/unreviewed/cxx',
                     'CFLAGS': '-include /unreviewed/header', 'CXXFLAGS': '-DUNREVIEWED=1',
                     'LDFLAGS': '-L/unreviewed/lib', 'CPATH': '/unreviewed/include',
                     'SDKROOT': '/unreviewed/sdk', 'PKG_CONFIG_PATH': '/unreviewed/pkgconfig'}
        with patch.dict(os.environ, dangerous), patch.object(runtime, 'run_steps', return_value=[]) as steps:
            state = runtime.validate(self.args, self.built_state())
        self.assertEqual(state['phase'], 'graphics_validated_gameplay_pending')
        self.assertTrue(state['graphics_validation_executed'])
        self.assertFalse(state['gameplay_validated'])
        self.assertEqual(steps.call_count, 1)
        for key in dangerous:
            self.assertFalse(key in steps.call_args.args[3], 'Unexpected inherited override: ' + key)
        self.assertEqual(list(self.locks.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
