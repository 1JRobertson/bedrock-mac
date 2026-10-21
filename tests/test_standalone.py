"""Isolation checks for the standalone launcher; no running game is touched."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('standalone', Path(__file__).resolve().parents[1] / 'client/standalone.py')
standalone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(standalone)


class IsolationTests(unittest.TestCase):
    def test_source_code_paths_are_independent_of_selected_data_home(self):
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'BEDROCK_HOME': temporary}):
            with patch.dict(os.environ):
                os.environ.pop('BEDROCK_BUNDLE', None)
                selected = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(selected)
                self.assertEqual(selected.ROOT, Path(temporary))
                self.assertEqual(selected.SOURCE_ROOT, source)
                self.assertEqual(selected.SCRIPTS, source / 'client')
                picker = selected.picker_bridge()
                self.assertEqual(Path(picker.__file__), source / 'client/standalone-pickers.py')
                self.assertEqual(picker.source_root(), source)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_flat_packaged_scripts_keep_existing_data_paths(self):
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            home, bundle = Path(temporary) / 'data', Path(temporary) / 'app'
            home.mkdir()
            scripts = bundle / 'scripts'
            scripts.mkdir(parents=True)
            runtime = home / 'standalone.py'
            runtime.write_bytes((source / 'client/standalone.py').read_bytes())
            (scripts / 'standalone-pickers.py').write_bytes((source / 'client/standalone-pickers.py').read_bytes())
            with patch.dict(os.environ, {'BEDROCK_HOME': str(home), 'BEDROCK_BUNDLE': str(bundle)}):
                bundled_spec = importlib.util.spec_from_file_location('flat_runtime', runtime)
                bundled = importlib.util.module_from_spec(bundled_spec)
                bundled_spec.loader.exec_module(bundled)
                self.assertEqual(bundled.ROOT, home)
                self.assertEqual(bundled.PREFIX, home / 'bottles/Bedrock-Standalone')
                self.assertEqual(bundled.SCRIPTS, home.resolve())
                picker = bundled.picker_bridge()
                self.assertEqual(Path(picker.__file__), scripts / 'standalone-pickers.py')
                self.assertEqual(picker.source_root(), scripts)

    def test_registry_import_uses_code_bytes_and_owned_data_prefix_then_cleans_up(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data, scripts = root / 'data', root / 'source/client'
            prefix = data / 'bottles/Bedrock-Standalone'
            prefix.mkdir(parents=True)
            scripts.mkdir(parents=True)
            (scripts / 'winrt.reg').write_bytes(b'reviewed registry source')
            seen = []
            def wine(command, game, **kwargs):
                self.assertEqual(command[:2], ['reg', 'import'])
                self.assertTrue(command[2].startswith('R:\\bottles\\Bedrock-Standalone\\.bedrock-winrt-'))
                registry = data / command[2][3:].replace('\\', '/')
                self.assertEqual(registry.read_bytes(), b'reviewed registry source')
                self.assertEqual(registry.stat().st_mode & 0o777, 0o600)
                seen.append(registry)
            with patch.object(standalone, 'ROOT', data), patch.object(standalone, 'SCRIPTS', scripts), \
                    patch.object(standalone, 'PREFIX', prefix), patch.object(standalone, 'wine_run', side_effect=wine):
                standalone.import_winrt_registry(data / 'game', None)
            self.assertEqual(len(seen), 1)
            self.assertFalse(seen[0].exists())
            self.assertEqual(list(prefix.iterdir()), [])

    def test_registry_import_accepts_a_relative_data_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'source'
            scripts.mkdir()
            (scripts / 'winrt.reg').write_bytes(b'reviewed registry source')
            previous = Path.cwd()
            try:
                os.chdir(root)
                data = Path('relative-data')
                prefix = data / 'bottles/Bedrock-Standalone'
                prefix.mkdir(parents=True)
                imported = []
                def wine(command, game, **kwargs):
                    self.assertTrue(command[2].startswith('R:\\bottles\\Bedrock-Standalone\\.bedrock-winrt-'))
                    registry = data / command[2][3:].replace('\\', '/')
                    self.assertEqual(registry.read_bytes(), b'reviewed registry source')
                    imported.append(registry)
                with patch.object(standalone, 'ROOT', data), patch.object(standalone, 'PREFIX', prefix), \
                        patch.object(standalone, 'SCRIPTS', scripts), patch.object(standalone, 'wine_run', side_effect=wine):
                    standalone.import_winrt_registry(data / 'game', None)
                self.assertEqual(len(imported), 1)
                self.assertEqual(list(prefix.iterdir()), [])
            finally:
                os.chdir(previous)

    def test_helper_receipt_is_private_atomic_and_does_not_follow_existing_link(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'unrelated'
            target.write_bytes(b'keep this file')
            state = root / 'session.json'
            state.symlink_to(target)
            with patch.object(standalone, 'STATE', state), patch.object(standalone, 'HELPER', root / 'helper'):
                previous_umask = os.umask(0)
                try:
                    standalone.record_account_process(43210)
                finally:
                    os.umask(previous_umask)
            self.assertFalse(state.is_symlink())
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(state.read_text()), {'pid': 43210, 'executable': str(root / 'helper')})
            self.assertEqual(target.read_bytes(), b'keep this file')
            self.assertEqual(list(root.glob('.helper-session-*')), [])

    def test_failed_receipt_publish_preserves_previous_complete_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = root / 'session.json'
            state.write_bytes(b'previous complete record')
            with patch.object(standalone, 'STATE', state), \
                 patch.object(standalone.os, 'replace', side_effect=OSError('fixture disk error')):
                with self.assertRaises(OSError):
                    standalone.record_account_process(43210)
            self.assertEqual(state.read_bytes(), b'previous complete record')
            self.assertEqual(list(root.glob('.helper-session-*')), [])

    def test_owned_helper_gets_current_parent_and_receipt_before_readiness_poll(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper, state = root / 'helper', root / 'session.json'
            helper.touch()
            process = Mock(pid=43210)
            process.poll.return_value = 0
            polls = 0

            def ready():
                nonlocal polls
                polls += 1
                if polls == 1:
                    self.assertFalse(state.exists())
                    return False
                self.assertEqual(json.loads(state.read_text())['pid'], process.pid)
                self.assertEqual(state.stat().st_mode & 0o777, 0o600)
                return True

            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'HELPER', helper), \
                 patch.object(standalone, 'STATE', state), patch.object(standalone, 'SOCKET', root / 'unused.sock'), \
                 patch.object(standalone, 'recover_account_socket'), \
                 patch.object(standalone, 'account_ready', side_effect=ready), \
                 patch.object(standalone, 'account_pid', return_value=None), \
                 patch.object(standalone.subprocess, 'Popen', return_value=process) as spawn, \
                 patch.dict(os.environ, {'BEDROCK_HELPER_PARENT_PID': '2', 'BEDROCK_HELPER_SESSION_FILE': '/stale/session.json'}):
                with standalone.account(root, progress=lambda _line: None):
                    env = spawn.call_args.kwargs['env']
                    self.assertEqual(env['BEDROCK_HELPER_PARENT_PID'], str(os.getpid()))
                    self.assertEqual(env['BEDROCK_HELPER_SESSION_FILE'], str(state.absolute()))
                self.assertEqual(os.environ['BEDROCK_HELPER_PARENT_PID'], '2')
            self.assertEqual(polls, 2)

    def test_receipt_failure_stops_only_newly_owned_helper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / 'helper'
            helper.touch()
            process = Mock(pid=43210)
            process.poll.return_value = None
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'HELPER', helper), \
                 patch.object(standalone, 'STATE', root / 'session.json'), \
                 patch.object(standalone, 'SOCKET', root / 'unused.sock'), \
                 patch.object(standalone, 'recover_account_socket'), \
                 patch.object(standalone, 'account_ready', return_value=False), \
                 patch.object(standalone, 'account_pid', return_value=None), \
                 patch.object(standalone, 'record_account_process', side_effect=OSError('fixture disk error')), \
                 patch.object(standalone.subprocess, 'Popen', return_value=process):
                with self.assertRaises(OSError):
                    with standalone.account(root, progress=lambda _line: None):
                        self.fail('Receipt failure must prevent account use')
            process.send_signal.assert_called_once_with(standalone.signal.SIGINT)

    def test_interrupted_update_blocks_all_cli_mutation_under_lock_and_preserves_saves(self):
        for journal in ('preparing', 'malformed', 'empty', 'file', 'dangling-link'):
            for command in (['launch'], ['prepare'], ['probe', 'graphics'], ['probe', 'account']):
                with self.subTest(journal=journal, command=command), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    transaction = root / '.minecraft-update'
                    if journal == 'file':
                        transaction.write_text('unexpected entry')
                    elif journal == 'dangling-link':
                        transaction.symlink_to(root / 'missing-journal')
                    else:
                        transaction.mkdir()
                        if journal != 'empty':
                            (transaction / 'transaction.json').write_text(
                                '{broken' if journal == 'malformed' else json.dumps({'phase': 'preparing'}))
                    prefix = root / 'bottles/Bedrock-Standalone'
                    world = prefix / 'worlds/disposable/level.dat'
                    world.parent.mkdir(parents=True)
                    world.write_bytes(b'current saved world')
                    previous_root = transaction / 'previous-prefix' if transaction.is_dir() else root / 'preserved-previous-prefix'
                    previous = previous_root / 'worlds/disposable/level.dat'
                    previous.parent.mkdir(parents=True)
                    previous.write_bytes(b'previous saved world')
                    original_guard = standalone.refuse_pending_update

                    def guard_while_locked():
                        with (root / 'runtime/standalone/launcher.lock').open('a') as other:
                            with self.assertRaises(BlockingIOError):
                                standalone.fcntl.flock(other, standalone.fcntl.LOCK_EX | standalone.fcntl.LOCK_NB)
                        original_guard()

                    with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'PREFIX', prefix), \
                         patch.object(standalone, 'refuse_pending_update', side_effect=guard_while_locked), \
                         patch.object(standalone, 'prepare') as prepare, \
                         patch.object(standalone, 'install_pending_hud') as hud, \
                         patch.object(standalone, 'account') as account, \
                         patch.object(standalone, 'wine_run') as wine, \
                         patch.object(sys, 'argv', ['standalone.py', *command]):
                        previous_umask = os.umask(0o077)
                        try:
                            with self.assertRaisesRegex(RuntimeError, 'update needs recovery'):
                                standalone.main()
                        finally:
                            os.umask(previous_umask)
                    for operation in (prepare, hud, account, wine):
                        operation.assert_not_called()
                    self.assertEqual(world.read_bytes(), b'current saved world')
                    self.assertEqual(previous.read_bytes(), b'previous saved world')
                    self.assertTrue(os.path.lexists(transaction))

    def test_updater_can_prepare_directly_while_it_owns_transaction_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / 'bottles/Bedrock-Standalone'
            (root / '.minecraft-update').mkdir()
            lock_path = root / 'runtime/standalone/launcher.lock'
            lock_path.parent.mkdir(parents=True)
            with lock_path.open('w') as lock:
                standalone.fcntl.flock(lock, standalone.fcntl.LOCK_EX)
                with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'PREFIX', prefix), \
                     patch.object(standalone, 'prerequisites'), \
                     patch.object(standalone, 'setup_signature', return_value={}), \
                     patch.object(standalone, 'setup_matches', return_value=True), \
                     patch.object(standalone, 'picker_bridge') as pickers, \
                     patch.object(standalone, 'map_drive') as mapping:
                    pickers.return_value.installed.return_value = True
                    standalone.prepare(root / 'game')
                self.assertEqual(mapping.call_count, 2)

    def test_unstaged_runtime_needs_no_optional_allocator_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(standalone, 'WINE', Path(temporary)), \
                 patch.object(standalone.importlib.util, 'spec_from_file_location') as load:
                self.assertFalse(standalone.verified_refmove_activation(Path('/owned-game')))
                load.assert_not_called()

    def test_unknown_picker_registration_stops_prepare_before_wineboot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / 'bottles/Bedrock-Standalone'
            prefix.mkdir(parents=True)
            registry = ('WINE REGISTRY Version 2\n[Software\\\\Microsoft\\\\WindowsRuntime\\\\ActivatableClassId'
                        '\\\\Windows.Storage.Pickers.FileOpenPicker] 123\n"DllPath"="custom.dll"\n')
            (prefix / 'system.reg').write_text(registry)
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'PREFIX', prefix), \
                 patch.object(standalone, 'prerequisites'), \
                 patch.object(standalone, 'setup_signature', return_value={}), \
                 patch.object(standalone, 'wait_for_idle_prefix'), \
                 patch.object(standalone, 'wine_run') as wine:
                with self.assertRaisesRegex(RuntimeError, 'registration must be preserved'):
                    standalone.prepare(root / 'game')
                wine.assert_not_called()
            self.assertEqual((prefix / 'system.reg').read_text(), registry)
            self.assertFalse((prefix / 'drive_c').exists())

    def test_inherited_allocator_and_sentinel_gates_are_removed(self):
        with patch.dict(os.environ, {'BEDROCK_PRIVATE_REFMOVE_15203': '1',
                                     'BEDROCK_PRIVATE_REFMOVE_SENTINEL': '1',
                                     'BEDROCK_FRAME_SLAB': '1',
                                     'BEDROCK_FRAME_SLAB_CONTROL': 'Z:\\old.bin',
                                     'BEDROCK_FRAME_SLAB_SENTINEL': '1',
                                     'BEDROCK_CLONE_RECURRENCE': '1',
                                     'BEDROCK_BINDING_RECURRENCE': '1',
                                     'BEDROCK_EXACT_CURRENT': 'fast',
                                     'BEDROCK_ALLOC_DIAG': '1',
                                     'BEDROCK_ALLOCATOR_DIAGNOSTIC': '1'}):
            env = standalone.environment()
        self.assertFalse(any(key.startswith(('BEDROCK_PRIVATE_REFMOVE', 'BEDROCK_FRAME_SLAB',
            'BEDROCK_CLONE_RECURRENCE', 'BEDROCK_BINDING_RECURRENCE', 'BEDROCK_EXACT_CURRENT',
            'BEDROCK_ALLOC_DIAG', 'BEDROCK_ALLOCATOR_')) for key in env))

    def test_frame_profile_uses_unique_private_controls_only_for_game(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            wine = root / 'wine'; wine.mkdir()
            (wine / 'bedrock-frame-slab.json').write_text('{}')
            helper = Mock()
            helper.verified_activation.return_value = True
            game = root / 'game'
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'WINE', wine), \
                 patch.object(standalone, 'require'), \
                 patch.object(standalone.importlib.util, 'module_from_spec', return_value=helper), \
                 patch.object(standalone.importlib.util, 'spec_from_file_location'), \
                 patch.object(standalone, 'verified_refmove_activation') as old_verify, \
                 patch.object(standalone.subprocess, 'run') as run:
                standalone.wine_run(['G:\\Minecraft.Windows.exe'], game)
                first = run.call_args.kwargs['env']
                standalone.wine_run(['G:\\Minecraft.Windows.exe'], game)
                second = run.call_args.kwargs['env']
                self.assertNotEqual(first['BEDROCK_FRAME_SLAB_CONTROL'], second['BEDROCK_FRAME_SLAB_CONTROL'])
                helper.verified_activation.assert_called_with(wine, game)
                old_verify.assert_not_called()
                for env in (first, second):
                    self.assertEqual(env['BEDROCK_FRAME_SLAB_CHUNK'], '16384')
                    self.assertEqual(env['BEDROCK_PRIVATE_REFMOVE_15203'], '1')
                    control = Path(env['BEDROCK_FRAME_SLAB_CONTROL'][2:].replace('\\', '/'))
                    self.assertFalse(control.exists())
                    self.assertEqual(control.parent.stat().st_mode & 0o777, 0o700)
                    self.assertEqual(control.parent.parent, root / 'logs/standalone/frame-slab')
                helper.verified_activation.reset_mock()
                standalone.wine_run(['wineboot', '-u'], game)
                helper.verified_activation.assert_not_called()
                self.assertNotIn('BEDROCK_FRAME_SLAB', run.call_args.kwargs['env'])

    def test_invalid_frame_install_never_launches_or_falls_back(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / 'bedrock-frame-slab.json').write_text('{}')
            helper = Mock()
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'WINE', root), \
                 patch.object(standalone, 'require'), \
                 patch.object(standalone.importlib.util, 'module_from_spec', return_value=helper), \
                 patch.object(standalone.importlib.util, 'spec_from_file_location'), \
                 patch.object(standalone, 'verified_refmove_activation') as old_verify, \
                 patch.object(standalone.subprocess, 'run') as run:
                for failure in (False, RuntimeError('Changed runtime')):
                    helper.verified_activation.side_effect = failure if isinstance(failure, Exception) else None
                    helper.verified_activation.return_value = False
                    with self.assertRaises(RuntimeError):
                        standalone.wine_run(['G:\\Minecraft.Windows.exe'], root / 'game')
                    run.assert_not_called()
                    old_verify.assert_not_called()
                self.assertFalse((root / 'logs').exists())

    def test_unstaged_frame_profile_loads_no_optional_module(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(standalone, 'WINE', Path(temporary)), \
             patch.object(standalone.importlib.util, 'spec_from_file_location') as load:
            self.assertFalse(standalone.apply_frame_slab({}, Path('/owned-game')))
            load.assert_not_called()

    def test_only_verified_game_launch_receives_allocator_gate(self):
        game = Path('/owned-game')
        with patch.object(standalone, 'require'), \
             patch.object(standalone, 'apply_frame_slab', return_value=False), \
             patch.object(standalone, 'verified_refmove_activation', return_value=True) as verify, \
             patch.object(standalone.subprocess, 'run') as run:
            standalone.wine_run(['G:\\Minecraft.Windows.exe'], game)
            verify.assert_called_once_with(game)
            self.assertEqual(run.call_args.kwargs['env']['BEDROCK_PRIVATE_REFMOVE_15203'], '1')
            verify.reset_mock()
            standalone.wine_run(['wineboot', '-u'], game)
            verify.assert_not_called()
            self.assertNotIn('BEDROCK_PRIVATE_REFMOVE_15203', run.call_args.kwargs['env'])

    def test_disabled_or_failed_allocator_stage_cannot_activate(self):
        with patch.object(standalone, 'require'), \
             patch.object(standalone, 'apply_frame_slab', return_value=False), \
             patch.object(standalone, 'verified_refmove_activation', return_value=False) as verify, \
             patch.object(standalone.subprocess, 'run') as run:
            standalone.wine_run(['G:\\Minecraft.Windows.exe'], Path('/owned-game'))
            self.assertNotIn('BEDROCK_PRIVATE_REFMOVE_15203', run.call_args.kwargs['env'])
            run.reset_mock()
            verify.side_effect = RuntimeError('Corrupt stage')
            with self.assertRaisesRegex(RuntimeError, 'Corrupt stage'):
                standalone.wine_run(['G:\\Minecraft.Windows.exe'], Path('/owned-game'))
            run.assert_not_called()

    def test_network_diagnostics_are_explicit_and_do_not_enable_http_payload_tracing(self):
        with patch.dict(os.environ, {'WINEDEBUG': '+all', 'WINEGDK_HTTP_STATUS_TRACE': '1'}):
            normal = standalone.environment()
            diagnostic = standalone.environment(network_diagnostics=True)
        self.assertEqual(normal['WINEDEBUG'], '-all')
        self.assertNotIn('WINEGDK_HTTP_STATUS_TRACE', normal)
        self.assertEqual(diagnostic['WINEGDK_HTTP_STATUS_TRACE'], '1')
        self.assertEqual(diagnostic['WINEDEBUG'], '-all,+timestamp,+xuser,+wsdiag,fixme+gdkc,err+seh')

    def test_inherited_runtime_cannot_select_crossover_or_old_prefix(self):
        with patch.dict(os.environ, {'CX_BOTTLE': 'Bedrock-Mac', 'WINEPREFIX': '/old/prefix',
                                     'WINEDLLPATH': '/CrossOver/lib', 'DYLD_LIBRARY_PATH': '/CrossOver/lib'}):
            env = standalone.environment()
        self.assertEqual(env['WINEPREFIX'], str(standalone.PREFIX))
        self.assertEqual(env['WINEDLLPATH'], str(standalone.DXMT))
        self.assertFalse(any(key.startswith(('CX_', 'DYLD_')) for key in env))
        self.assertNotIn('/CrossOver/', ':'.join(env.values()))

    def test_existing_drive_cannot_be_repointed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / 'prefix'
            (prefix / 'dosdevices').mkdir(parents=True)
            first, second = root / 'first', root / 'second'
            first.mkdir()
            second.mkdir()
            with patch.object(standalone, 'PREFIX', prefix):
                standalone.map_drive('g', first)
                standalone.map_drive('g', first)
                with self.assertRaises(RuntimeError):
                    standalone.map_drive('g', second)
            self.assertEqual((prefix / 'dosdevices/g:').resolve(), first.resolve())

    def test_damaged_setup_record_is_repairable(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            (prefix / '.bedrock-setup.json').write_text('{interrupted')
            with patch.object(standalone, 'PREFIX', prefix):
                self.assertFalse(standalone.setup_matches({'setup_version': 2}))

    def test_setup_record_preserves_existing_staging_files_and_links(self):
        for linked in (False, True):
            with self.subTest(linked=linked), tempfile.TemporaryDirectory() as temporary:
                prefix = Path(temporary)
                world = prefix / 'world-backup'
                world.write_bytes(b'preserve world bytes')
                staging = prefix / '.bedrock-setup.new'
                if linked:
                    staging.symlink_to(world)
                else:
                    staging.write_bytes(b'preserve staged setup')
                desired = {'setup_version': 4, 'game': '/fixture/game'}
                with patch.object(standalone, 'PREFIX', prefix):
                    standalone.write_setup_record(desired)
                    self.assertTrue(standalone.setup_matches(desired))
                self.assertEqual(world.read_bytes(), b'preserve world bytes')
                self.assertEqual(staging.is_symlink(), linked)
                self.assertEqual(staging.read_bytes(), b'preserve world bytes' if linked else b'preserve staged setup')
                self.assertFalse((prefix / '.bedrock-setup.json').is_symlink())

    def test_failed_setup_record_replacement_preserves_previous_complete_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary)
            marker = prefix / '.bedrock-setup.json'
            marker.write_bytes(b'previous complete setup')
            with patch.object(standalone, 'PREFIX', prefix), \
                 patch.object(standalone.os, 'replace', side_effect=OSError('fixture disk error')):
                with self.assertRaisesRegex(OSError, 'fixture disk error'):
                    standalone.write_setup_record({'setup_version': 4})
            self.assertEqual(marker.read_bytes(), b'previous complete setup')
            self.assertEqual(set(prefix.iterdir()), {marker})

    def test_dll_only_app_update_invalidates_setup_without_changing_wine_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wine, dxmt, game = root / 'wine', root / 'dxmt', root / 'game'
            files = [wine / 'bin/wine', dxmt / 'x86_64-windows/d3d11.dll',
                     game / 'Installers/GameInputRedist.msi', wine / 'file-pickers-build.json']
            modules = ('x86_64-windows/ntdll.dll', 'x86_64-unix/ntdll.so',
                       'x86_64-windows/xgameruntime.dll', 'x86_64-windows/d3d11.dll',
                       'x86_64-windows/dxgi.dll', 'x86_64-windows/d3d10core.dll',
                       'x86_64-windows/winemetal.dll', 'x86_64-unix/winemetal.so',
                       'x86_64-windows/bedrock-pickers.dll')
            files.extend(wine / 'lib/wine' / name for name in modules)
            for path in files:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'original')
            with patch.object(standalone, 'WINE', wine), patch.object(standalone, 'DXMT', dxmt), \
                 patch.object(standalone, 'PREFIX', root):
                original = standalone.setup_signature(game)
                (root / '.bedrock-setup.json').write_text(json.dumps(original))
                self.assertTrue(standalone.setup_matches(standalone.setup_signature(game)))
                for name in modules:
                    with self.subTest(module=name):
                        module = wine / 'lib/wine' / name
                        module.write_bytes(b'updated')
                        changed = standalone.setup_signature(game)
                        self.assertEqual(original['wine'], changed['wine'])
                        self.assertFalse(standalone.setup_matches(changed))
                        module.write_bytes(b'original')
                self.assertTrue(standalone.setup_matches(standalone.setup_signature(game)))

    def test_account_timeout_stops_owned_helper_and_preserves_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / 'helper'
            helper.touch()
            child = unittest.mock.Mock(pid=43210)
            child.poll.return_value = None
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'HELPER', helper), \
                    patch.object(standalone, 'STATE', root / 'state.json'), \
                    patch.object(standalone, 'account_ready', return_value=False), \
                    patch.object(standalone, 'account_pid', side_effect=lambda: 43210 if (root / 'state.json').exists() else None), \
                    patch.object(standalone, 'SOCKET', root / 'account.sock'), \
                    patch.object(standalone.subprocess, 'Popen', return_value=child), \
                    patch.object(standalone.time, 'monotonic', side_effect=[0, 2000]):
                with self.assertRaises(standalone.AccountError) as raised:
                    with standalone.account(root / 'game', timeout=10):
                        self.fail('A helper without a ready socket must not launch Minecraft')
                self.assertEqual(raised.exception.code, 'account_timeout')
            child.send_signal.assert_called_once()
            self.assertFalse((root / 'state.json').exists())

    def test_symlink_account_socket_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / 'real.sock'
            link = root / 'link.sock'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(original))
                original.chmod(0o600)
                link.symlink_to(original)
                with patch.object(standalone, 'SOCKET', link):
                    with self.assertRaises(RuntimeError):
                        standalone.account_ready()

    def test_unknown_socket_owner_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'account.sock'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(path))
                path.chmod(0o600)
                with patch.object(standalone, 'SOCKET', path), patch.object(standalone, 'account_pid', return_value=None):
                    with self.assertRaises(RuntimeError):
                        standalone.account_ready()


    def socket_fixture(self, root):
        path = root / 'account.sock'
        state = root / 'session.json'
        state.write_text(json.dumps({'pid': 999999, 'executable': str(standalone.HELPER)}))
        return path, state

    def test_crashed_recorded_helper_socket_is_recovered(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, state = self.socket_fixture(Path(temporary))
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(path))
                path.chmod(0o600)
            with patch.object(standalone, 'SOCKET', path), patch.object(standalone, 'STATE', state), \
                 patch.object(standalone, 'account_pid', return_value=None), \
                 patch.object(standalone.os, 'kill', side_effect=ProcessLookupError):
                standalone.recover_account_socket()
                self.assertFalse(path.exists())

    def test_listening_socket_survives_stale_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, state = self.socket_fixture(Path(temporary))
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(path))
                path.chmod(0o600)
                connection.listen(1)
                with patch.object(standalone, 'SOCKET', path), patch.object(standalone, 'STATE', state), \
                     patch.object(standalone, 'account_pid', return_value=None), \
                     patch.object(standalone.os, 'kill', side_effect=ProcessLookupError):
                    standalone.recover_account_socket()
                    self.assertTrue(path.exists())

    def test_unrecorded_dead_socket_is_not_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'account.sock'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(path))
                path.chmod(0o600)
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'SOCKET', path), \
                 patch.object(standalone, 'STATE', root / 'missing.json'), \
                 patch.object(standalone, 'account_pid', return_value=None):
                standalone.recover_account_socket()
                self.assertTrue(path.exists())



    def test_failed_socket_cleanup_keeps_recovery_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'account.sock'
            path.write_text('preserved endpoint')
            state = root / 'session.json'
            helper = root / 'helper'
            helper.touch()
            process = Mock(pid=999999)
            process.poll.return_value = 0
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'SOCKET', path), \
                 patch.object(standalone, 'STATE', state), patch.object(standalone, 'HELPER', helper), \
                 patch.object(standalone, 'account_ready', side_effect=[False, True]), \
                 patch.object(standalone, 'account_pid', return_value=None), \
                 patch.object(standalone, 'recover_account_socket'), \
                 patch.object(standalone.subprocess, 'Popen', return_value=process):
                with standalone.account(root):
                    pass
            self.assertTrue(path.exists())
            self.assertEqual(json.loads(state.read_text())['pid'], process.pid)



    def test_rebuilt_graphics_requires_matching_libraries_and_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wine, dxmt = root / 'wine', root / 'dxmt'
            installed = wine / 'lib/wine/x86_64-unix'
            installed.mkdir(parents=True)
            (dxmt / 'x86_64-unix').mkdir(parents=True)
            (root / 'patches').mkdir()
            patch_file = root / 'patches/standalone-dxmt-memory-lifetime.patch'
            trace = root / 'native/graphics/standalone-dxmt-display-trace.c'
            trace.parent.mkdir(parents=True)
            patch_file.write_text('reviewed patch')
            trace.write_text('reviewed trace source')
            (dxmt / 'x86_64-unix/winemetal.so').write_bytes(b'upstream')
            (installed / 'winemetal-upstream.so').write_bytes(b'upstream')
            (installed / 'winemetal.so').write_bytes(b'rebuilt bridge')
            metadata = {
                'version': 'v0.80',
                'source_commit': '589adb780354b461645b29999cefaf533594ee99',
                'files': {name: standalone.sha256(installed / name)
                          for name in ('winemetal.so', 'winemetal-upstream.so')},
                'patch_sha256': standalone.sha256(patch_file),
                'trace_source_sha256': standalone.sha256(trace),
            }
            (wine / 'dxmt-unix-bridge.json').write_text(json.dumps(metadata))
            with patch.object(standalone, 'ROOT', root), patch.object(standalone, 'SOURCE_ROOT', root), \
                 patch.object(standalone, 'WINE', wine), patch.object(standalone, 'DXMT', dxmt):
                standalone.verify_unix_bridge()
                (installed / 'winemetal-upstream.so').write_bytes(b'wrong dependency')
                with self.assertRaises(RuntimeError):
                    standalone.verify_unix_bridge()
                (installed / 'winemetal-upstream.so').write_bytes(b'upstream')
                patch_file.write_text('changed patch awaiting rebuild')
                with self.assertRaises(RuntimeError):
                    standalone.verify_unix_bridge()


if __name__ == '__main__':
    unittest.main()
