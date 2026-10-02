"""Exercise the real worker entry point without network, Keychain, or game access."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import socket
import os
import signal
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('onboarding', Path(__file__).resolve().parents[1] / 'launcher/setup.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
runtime_spec = importlib.util.spec_from_file_location('session_runtime', Path(__file__).resolve().parents[1] / 'standalone.py')
runtime = importlib.util.module_from_spec(runtime_spec)
runtime_spec.loader.exec_module(runtime)


class OnboardingTests(unittest.TestCase):
    def test_install_and_launch_share_one_account_process(self):
        self.run_account_flow()

    def test_preparation_failure_stops_the_shared_helper_and_never_launches(self):
        self.run_account_flow(fail_prepare=True)

    def run_account_flow(self, fail_prepare=False):
        # Exercise the real worker orchestration and runtime account context.
        # The fake child provides a real private socket and counts each launch.
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            helper = root / 'helper'
            helper.touch()
            state, endpoint = root / 'session.json', root / 'account.sock'
            started, commands = [], []

            class Helper:
                pid = 32123
                def __init__(self, command, **kwargs):
                    started.append(command)
                    self.returncode = None
                    (root / 'game').mkdir(exist_ok=True)
                    self.socket = socket.socket(socket.AF_UNIX)
                    self.socket.bind(str(endpoint))
                    endpoint.chmod(0o600)
                    kwargs['stdout'].write(b'Finding the Windows package\nStarting Xbox account service.\n')
                    kwargs['stdout'].flush()
                def poll(self): return self.returncode
                def send_signal(self, _):
                    self.socket.close()
                    endpoint.unlink()
                    self.returncode = 0
                def wait(self, **_): return self.returncode

            def account_pid():
                return json.loads(state.read_text())['pid'] if state.exists() else None

            def command(command, *_args, **_kwargs):
                commands.append(command[-1])
                if command[-1] == 'prepare' and fail_prepare:
                    raise RuntimeError('Preparation failed')
                if command[-1] in ('--download-game', 'launch'):
                    with runtime.account(root / 'game'):
                        self.assertTrue(runtime.account_ready())

            with patch.object(worker, 'ROOT', root), patch.object(runtime, 'ROOT', root), \
                    patch.object(runtime, 'HELPER', helper), patch.object(runtime, 'STATE', state), \
                    patch.object(runtime, 'SOCKET', endpoint), patch.object(runtime, 'account_pid', account_pid), \
                    patch.object(runtime.subprocess, 'Popen', Helper), \
                    patch.object(worker, 'installed', return_value=False), \
                    patch.object(worker, 'load', return_value=runtime), \
                    patch.object(worker, 'validate_install', create=True), \
                    patch.object(worker, 'run', side_effect=command), \
                    patch.object(worker.platform, 'machine', return_value='arm64'), \
                    patch.object(worker.platform, 'mac_ver', return_value=('26.0', (), '')), \
                    patch.object(worker.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                    patch('sys.argv', ['setup.py']), contextlib.redirect_stdout(io.StringIO()):
                for relative in ('runtime/standalone/wine/build-manifest.json',
                                 'runtime/standalone/dxmt/manifest.json',
                                 'sources/xodus/target/release/examples/standalone_helper'):
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.touch()
                if fail_prepare:
                    with self.assertRaisesRegex(RuntimeError, 'Preparation failed'):
                        worker.main()
                else:
                    worker.main()
            self.assertEqual(len(started), 1, 'Setup must not start a second Keychain-reading helper for play')
            self.assertIn('--download', started[0])
            self.assertIn('--serve-after', started[0])
            self.assertEqual(commands, ['--threading', 'prepare'] + ([] if fail_prepare else ['launch']))
            self.assertFalse(endpoint.exists())
            self.assertFalse(state.exists())

    def test_keychain_failure_has_actionable_message(self):
        with tempfile.TemporaryFile() as log, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'macOS Keychain prompt'):
                worker.run([sys.executable, '-c', "print('BEDROCK_ERROR:keychain_access'); raise SystemExit(1)"],
                           log, 'Generic failure', account_progress=True)

    def test_account_failure_reports_known_stage_instead_of_blaming_signin(self):
        with tempfile.TemporaryFile() as log, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'download format'):
                worker.run([sys.executable, '-c', "print('BEDROCK_ERROR:package_format'); raise SystemExit(1)"],
                           log, 'Generic failure', account_progress=True)

    def test_unknown_helper_error_never_becomes_ui_text(self):
        with tempfile.TemporaryFile() as log, contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaisesRegex(RuntimeError, '^Generic failure$'):
                worker.run([sys.executable, '-c', "print('BEDROCK_ERROR:private-response'); raise SystemExit(1)"],
                           log, 'Generic failure', account_progress=True)
            self.assertNotIn('private-response', output.getvalue())

    def test_bundle_setup_preserves_worlds_and_relinks_after_app_move(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            home, bundle = folder / 'data', folder / 'app'
            (home / 'game').mkdir(parents=True)
            world = home / 'game/world.save'
            world.write_text('existing world')
            (bundle / 'scripts').mkdir(parents=True)
            for name in ('standalone.py', 'standalone-setup.py', 'standalone-gameinput.py', 'winrt.reg'):
                (bundle / 'scripts' / name).write_text('bundled script')
            with patch.object(worker, 'ROOT', home), patch.object(worker, 'BUNDLE', bundle):
                worker.initialize_bundle()
                worker.initialize_bundle()
            moved = folder / 'moved-app'
            bundle.rename(moved)
            with patch.object(worker, 'ROOT', home), patch.object(worker, 'BUNDLE', moved):
                worker.initialize_bundle()
            self.assertEqual(world.read_text(), 'existing world')
            self.assertEqual((home / 'runtime/standalone/wine').resolve(), (moved / 'runtime/wine').resolve())

    def test_first_install_uses_only_bundled_components(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(worker, 'ROOT', Path(folder)), \
                patch.object(worker.platform, 'machine', return_value='arm64'), \
                patch.object(worker.platform, 'mac_ver', return_value=('26.0', (), '')), \
                patch.object(worker.shutil, 'disk_usage', return_value=SimpleNamespace(free=10 * 1024**3)), \
                patch.object(worker.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(worker, 'run') as run, contextlib.redirect_stdout(io.StringIO()):
            for relative in ('runtime/standalone/wine/build-manifest.json',
                             'runtime/standalone/dxmt/manifest.json',
                             'sources/xodus/target/release/examples/standalone_helper'):
                path = Path(folder) / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            with tempfile.TemporaryFile() as log:
                worker.install(log)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual([command[-1] for command in commands], ['--threading', 'prepare'])
            self.assertEqual([Path(command[1]).name for command in commands],
                             ['standalone-setup.py', 'standalone.py'])

    def test_returning_player_skips_installation_and_launches(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(worker, 'ROOT', Path(folder)), \
                patch.object(worker, 'installed', return_value=True), patch.object(worker, 'validate_install'), \
                patch.object(worker, 'load', return_value=SimpleNamespace(
                    account=lambda *a, **kw: contextlib.nullcontext(), AccountError=runtime.AccountError)), \
                patch.object(worker, 'install') as install, patch.object(worker, 'run') as run, \
                patch('sys.argv', ['setup.py']), contextlib.redirect_stdout(io.StringIO()) as output:
            worker.main()
            install.assert_not_called()
            self.assertEqual(run.call_args.args[0][-1], 'launch')
            self.assertEqual(json.loads(output.getvalue().splitlines()[-1])['state'], 'ready')

    def test_failed_setup_never_launches_the_game(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(worker, 'ROOT', Path(folder)), \
                patch.object(worker, 'installed', return_value=False), \
                patch.object(worker, 'validate_install'), \
                patch.object(worker, 'load', return_value=SimpleNamespace(
                    account=lambda *a, **kw: contextlib.nullcontext(), AccountError=runtime.AccountError)), \
                patch.object(worker, 'install', side_effect=RuntimeError('Setup failed')), \
                patch.object(worker, 'run') as run, patch('sys.argv', ['setup.py']):
            with self.assertRaisesRegex(RuntimeError, 'Setup failed'):
                worker.main()
            run.assert_not_called()

    def test_download_progress_advances_and_rejects_invalid_counts(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            worker.account_update(b'Downloaded 500/1000 files.\n')
            worker.account_update(b'Downloaded 1000/1000 files.\n')
            worker.account_update(b'Downloaded 1/0 files.\n')
            worker.account_update(b'Downloaded 2/1 files.\n')
        statuses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(statuses), 2)
        self.assertLess(statuses[0]['progress'], statuses[1]['progress'])
        self.assertTrue(all(0 <= event['progress'] <= 1 for event in statuses))

    def test_cancel_stops_owned_command(self):
        child = unittest.mock.Mock(pid=98765)
        child.wait.side_effect = [worker.Cancelled(), 0]
        child.poll.return_value = None
        with tempfile.TemporaryFile() as log, \
                patch.object(worker.subprocess, 'Popen', return_value=child), \
                patch.object(worker.os, 'killpg') as kill:
            with self.assertRaises(worker.Cancelled):
                worker.run(['fake-download'], log, 'Failed')
        kill.assert_called_once_with(98765, worker.signal.SIGTERM)

    def test_cancel_terminates_a_real_download_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            pidfile = folder / 'download.pid'
            child_script = folder / 'download.py'
            child_script.write_text("import os, time, pathlib\npathlib.Path(" + repr(str(pidfile)) + ").write_text(str(os.getpid()))\ntime.sleep(60)\n")
            wrapper = folder / 'worker.py'
            wrapper.write_text("import importlib.util, signal\n"
                + "s=importlib.util.spec_from_file_location('worker', " + repr(worker.__file__) + ")\n"
                + "w=importlib.util.module_from_spec(s); s.loader.exec_module(w)\n"
                + "signal.signal(signal.SIGTERM,w.cancel)\n"
                + "try:\n with open(" + repr(str(folder / 'log')) + ", 'wb') as log: w.run("
                + repr([sys.executable, str(child_script)]) + ",log,'failed')\n"
                + "except w.Cancelled: pass\n")
            process = subprocess.Popen([sys.executable, str(wrapper)])
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if pidfile.exists() and pidfile.read_text().strip():
                        break
                    time.sleep(0.02)
                self.assertTrue(pidfile.exists(), 'Fixture download never started')
                pid = int(pidfile.read_text())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=10), 0)
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_upgrade_status_reads_the_new_bundled_script(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data, bundle = root / 'data', root / 'app'
            data.mkdir()
            (bundle / 'scripts').mkdir(parents=True)
            (data / 'standalone.py').write_text("raise RuntimeError('Old installed code must not run')")
            (bundle / 'scripts/standalone.py').write_text("VERSION = 'new'")
            with patch.object(worker, 'ROOT', data), patch.object(worker, 'BUNDLE', bundle):
                self.assertEqual(worker.load('fixture_runtime', 'standalone.py').VERSION, 'new')

    def test_status_does_not_install_or_launch(self):
        with patch.object(worker, 'installed', return_value=False), \
                patch.object(worker, 'install') as install, patch.object(worker, 'run') as run, \
                patch('sys.argv', ['setup.py', '--status']), contextlib.redirect_stdout(io.StringIO()) as output:
            worker.main()
            self.assertEqual(json.loads(output.getvalue())['state'], 'new')
            install.assert_not_called()
            run.assert_not_called()

    def test_command_failure_does_not_leak_process_output_to_ui(self):
        with tempfile.TemporaryFile() as log, \
                patch.object(worker.subprocess, 'Popen', return_value=unittest.mock.Mock(wait=lambda: 1, poll=lambda: 1)), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaisesRegex(RuntimeError, '^Friendly failure$'):
                worker.run(['false'], log, 'Friendly failure')
            self.assertEqual(output.getvalue(), '')


if __name__ == '__main__':
    unittest.main()
