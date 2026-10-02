#!/usr/bin/env python3
"""Local launcher worker. Only structured, credential-free status reaches the UI."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import runpy
# Included explicitly for the frozen worker's dynamically loaded scripts.
import xml.etree.ElementTree
import zipfile
import zlib
import datetime
import signal

FROZEN = getattr(sys, 'frozen', False)
BUNDLE = Path(os.environ['BEDROCK_BUNDLE']) if os.environ.get('BEDROCK_BUNDLE') else None
if BUNDLE:
    os.environ['BEDROCK_HOME'] = str(Path.home() / 'Library/Application Support/Bedrock for Mac')

# The frozen executable also runs the shipped Python scripts. No system Python
# or developer tools are required on the user's Mac.
if FROZEN and len(sys.argv) > 1 and sys.argv[1].endswith('.py'):
    script = Path(sys.argv[1]).resolve()
    allowed = {'standalone.py', 'standalone-setup.py', 'standalone-gameinput.py'}
    if script.name not in allowed or script.parent != Path(os.environ.get('BEDROCK_HOME', '')).resolve():
        raise SystemExit('Unknown bundled script')
    sys.argv = sys.argv[1:]
    runpy.run_path(str(script), run_name='__main__')
    raise SystemExit(0)

ROOT = Path(os.environ.get('BEDROCK_HOME', Path(__file__).resolve().parents[1]))
os.environ['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
os.environ.update(XODUS_LOG='off', RUST_LOG='off', PYTHONUNBUFFERED='1')

ACCOUNT_ERRORS = {
    'account_timeout': 'Sign-in took too long. Check your connection, then try again.',
    'signin_cancelled': 'Sign-in was closed. Try again when you’re ready.',
    'signin_failed': 'Microsoft sign-in did not finish. Check your connection and try again.',
    'device_auth': 'Could not connect to Microsoft sign-in. Check your connection and retry.',
    'keychain_access': 'Allow access to your saved sign-in in the macOS Keychain prompt, then retry.',
    'helper_stopped': 'The sign-in helper stopped unexpectedly. Open the setup log for details.',
    'catalog_lookup': 'Could not find Minecraft in Microsoft’s Windows catalog. Try again shortly.',
    'account_package': 'Microsoft could not provide the game download for this account. Try again shortly.',
    'package_selection': 'Microsoft returned an unexpected set of game packages. The launcher needs an update.',
    'package_connection': 'Could not connect to Microsoft’s game download. Check your connection and retry.',
    'package_size': 'Microsoft’s download size differs from its catalog. Try again shortly.',
    'package_cache': 'Could not save the download metadata. Check available disk space and retry.',
    'package_format': 'Minecraft’s download format could not be read. The launcher needs an update.',
    'package_files': 'Could not read the game’s file list. The launcher needs an update.',
    'package_segments': 'Could not read the game’s download segments. The launcher needs an update.',
    'package_filesystem': 'Could not read the game’s package filesystem. The launcher needs an update.',
    'content_license': 'Microsoft could not verify a Minecraft for Windows license for this account.',
    'download_failed': 'Minecraft preparation stopped. Open the setup log for details.',
}


def event(state, title, detail='', progress=None):
    print(json.dumps(dict(state=state, title=title, detail=detail, progress=progress)), flush=True)


def load(name, filename):
    source = BUNDLE / 'scripts' / filename if BUNDLE else ROOT / filename
    spec = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def initialize_bundle():
    if not BUNDLE:
        return
    ROOT.mkdir(parents=True, exist_ok=True)
    for filename in ('standalone.py', 'standalone-setup.py', 'standalone-gameinput.py', 'winrt.reg'):
        source = BUNDLE / 'scripts' / filename
        target = ROOT / filename
        if target.is_symlink():
            raise RuntimeError('An unexpected file blocks app setup: ' + filename)
        if not target.exists() or target.read_bytes() != source.read_bytes():
            temporary = target.with_suffix(target.suffix + '.new')
            temporary.write_bytes(source.read_bytes())
            os.replace(temporary, target)
    links = {
        'runtime/standalone/wine': 'runtime/wine',
        'runtime/standalone/dxmt': 'runtime/dxmt',
        'sources/xodus/target/release/examples/standalone_helper': 'standalone_helper',
    }
    for relative, bundled in links.items():
        destination = ROOT / relative
        target = BUNDLE / bundled
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_symlink():
            if destination.resolve() == target.resolve():
                continue
            destination.unlink()
        elif destination.exists():
            raise RuntimeError('An existing installation blocks app setup: ' + relative)
        destination.symlink_to(target)


def installed():
    if not (ROOT / 'standalone.py').is_file():
        return False
    runtime = load('standalone', 'standalone.py')
    try:
        runtime.prerequisites(ROOT / 'game')
        return runtime.HELPER.is_file() and runtime.setup_matches(runtime.setup_signature(ROOT / 'game'))
    except (OSError, RuntimeError):
        return False


def account_update(line):
    # Only these credential-free status lines reach the user interface.
    if line.startswith(b'Keychain: requesting saved sign-in entry'):
        event('busy', 'Signing you in', 'If macOS asks, “Always Allow” remembers access to your saved sign-in.', 0.2)
    elif line.startswith(b'Finding the Windows package'):
        event('busy', 'Checking your Minecraft purchase', '', 0.3)
    elif line.startswith(b'Downloading Minecraft '):
        event('busy', 'Downloading Minecraft', 'Keep this app open. Minecraft will start when it’s ready.', 0.5)
    elif line.startswith(b'Downloaded ') and b' files.' in line:
        import re
        match = re.fullmatch(rb'Downloaded (\d+)/(\d+) files\.\s*', line)
        if match:
            done, total = map(int, match.groups())
            if 0 <= done <= total and total > 0:
                event('busy', 'Downloading Minecraft', f'{done * 100 // total}%', 0.35 + 0.5 * done / total)


class Cancelled(BaseException):
    """User cancellation unwinds owned processes without reporting a failure."""


def stop_command(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def run(command, log, failure, account_progress=False):
    log.write(('\n$ ' + ' '.join(map(str, command)) + '\n').encode())
    log.flush()
    helper_error = None
    process = subprocess.Popen(list(map(str, command)), cwd=ROOT,
                               stdout=subprocess.PIPE if account_progress else log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        if account_progress:
            # Never forward arbitrary helper output to the UI.
            for line in process.stdout:
                log.write(line)
                log.flush()
                if line.startswith(b'BEDROCK_ERROR:'):
                    helper_error = ACCOUNT_ERRORS.get(line.strip().split(b':', 1)[1].decode('ascii', errors='replace'))
                account_update(line)
        code = process.wait()
    finally:
        stop_command(process)
        if account_progress and process.stdout:
            process.stdout.close()
    if code:
        raise RuntimeError(helper_error or failure)


def validate_install():
    minimum = '15.0'
    if BUNDLE:
        with (BUNDLE.parent / 'Info.plist').open('rb') as file:
            minimum = plistlib.load(file).get('LSMinimumSystemVersion', minimum)
    version = lambda text: tuple(int(part) for part in text.split('.'))
    if platform.machine() != 'arm64' or version(platform.mac_ver()[0] or '0') < version(minimum):
        raise RuntimeError(f'This build requires an Apple Silicon Mac with macOS {minimum} or later.')
    if subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode:
        raise RuntimeError('Rosetta is required to run Minecraft. See Bedrock for Mac Help in the Help menu for Apple’s setup instructions.')
    required = (ROOT / 'runtime/standalone/wine/build-manifest.json',
                ROOT / 'runtime/standalone/dxmt/manifest.json',
                ROOT / 'sources/xodus/target/release/examples/standalone_helper')
    if not all(path.is_file() for path in required):
        raise RuntimeError('This app is missing its bundled runtime. Use a complete build of Bedrock for Mac.')
    if not (ROOT / 'game/Minecraft.Windows.exe').is_file() and shutil.disk_usage(ROOT).free < 8 * 1024**3:
        raise RuntimeError('Free up at least 8 GB for Minecraft, then try again.')


def install(log):
    event('busy', 'Preparing Minecraft', 'Checking the required Microsoft game component…', 0.9)
    run([sys.executable, ROOT / 'standalone-setup.py', '--threading'], log,
        'Could not download the Microsoft game component. Check your connection and try again.')
    event('busy', 'Finishing setup', '', 0.95)
    run([sys.executable, ROOT / 'standalone.py', 'prepare'], log,
        'Could not finish setting up the game. Open the setup log for details.')


def main():
    os.umask(0o077)
    if '--status' in sys.argv:
        ready = installed()
        event('ready' if ready else 'new', 'Ready to play' if ready else 'Minecraft on your Mac')
        return
    folder = ROOT / 'logs/standalone'
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / 'onboarding.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Setup or Minecraft is already running. Return to the other launcher window.')
        initialize_bundle()
        with (folder / 'onboarding.log').open('ab') as log:
            ready = installed()
            if '--sign-out' in sys.argv:
                helper = ROOT / 'sources/xodus/target/release/examples/standalone_helper'
                event('busy', 'Signing out')
                run([helper.resolve(), '--sign-out', ROOT / 'game'], log,
                    'Could not sign out. Close Minecraft and try again.', account_progress=True)
                event('ready' if ready else 'new', 'Signed out', 'Choose Play to sign in with another Microsoft account.' if ready else '')
                return
            validate_install()
            if (ROOT / 'game').exists() and not (ROOT / 'game/Minecraft.Windows.exe').is_file():
                raise RuntimeError('The existing game installation is incomplete. Your files were kept. See Bedrock for Mac Help for recovery steps.')
            runtime = load('standalone_session', 'standalone.py')
            event('busy', 'Signing you in' if ready else 'Sign in to Microsoft',
                  '' if ready else 'Use the account that owns Minecraft for Windows.', 0.2)
            try:
                # One owner keeps the same helper alive through download,
                # prefix setup and gameplay. The child launcher reuses it.
                with runtime.account(ROOT / 'game', download=not (ROOT / 'game').exists(), progress=account_update):
                    if not ready:
                        install(log)
                    event('playing', 'Minecraft is running', 'You can close this window. Quit Minecraft to end your session.')
                    run([sys.executable, ROOT / 'standalone.py', 'launch'], log,
                        'Minecraft stopped unexpectedly. Open the setup log for details, then try again.')
            except runtime.AccountError as error:
                raise RuntimeError(ACCOUNT_ERRORS.get(error.code, str(error))) from error
            event('ready', 'Ready to play')


def cancel(_signal, _frame):
    raise Cancelled()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        main()
    except Cancelled:
        event('cancelled', 'Setup paused', 'Continue when you’re ready.')
    except (OSError, RuntimeError) as error:
        event('error', 'Setup needs attention', str(error))
        sys.exit(1)
