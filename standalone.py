#!/usr/bin/env python3
"""Run owned Windows Bedrock with the separately built Wine and DXMT runtime."""
import argparse
import contextlib
import datetime
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
WINE = ROOT / 'runtime/standalone/wine'
DXMT = ROOT / 'runtime/standalone/dxmt'
PREFIX = ROOT / 'bottles/Bedrock-Standalone'
STATE = ROOT / 'runtime/standalone/helper-session.json'
HELPER = ROOT / 'sources/xodus/target/release/examples/standalone_helper'
OLD_HELPER = ROOT / 'sources/xodus/target/release/examples/bedrock_helper'
SOCKET = Path('/tmp/xodus.sock')
THREADING_HASH = 'aa611155057ebd01cf315ad702a4b5725aa9d5e6fad87732c956fe0a1e5fcfba'
OVERRIDES = 'xgameruntime,windows.web,twinapi.appcore,windows.ui.core.textinput,wintypes=b;d3d11,dxgi,d3d10core,winemetal=b;d3d12,d3d12core,mscoree,mshtml='


def environment(*, network_diagnostics=False):
    # Keep the selected runtime independent of a shell's existing Wine/CrossOver session.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('CX_', 'WINE', 'DYLD_'))}
    env.update(WINEPREFIX=str(PREFIX), WINEARCH='win64', WINEDEBUG='-all',
               WINEDLLPATH=str(DXMT), WINEDLLOVERRIDES=OVERRIDES,
               LC_ALL='en_US.UTF-8')
    if network_diagnostics:
        # XUser's observer records HTTP host/status only, never headers or bodies.
        env['WINEDEBUG'] = '-all,+timestamp,+xuser,+wsdiag,fixme+gdkc,err+seh'
        env['WINEGDK_HTTP_STATUS_TRACE'] = '1'
    return env


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def account_pid():
    for state, expected in ((STATE, HELPER), (ROOT / 'runtime/helper-session.json', OLD_HELPER)):
        try:
            data = json.loads(state.read_text())
            pid = int(data['pid'])
            if pid <= 1 or data['executable'] != str(expected):
                continue
            command = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
            actual = Path(command)
            if not actual.is_absolute():
                actual = ROOT / actual
            if actual.resolve() == expected.resolve():
                return pid
        except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
            continue
    return None


def account_ready():
    try:
        info = SOCKET.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('The account socket has unexpected ownership or permissions.')
    if not account_pid():
        raise RuntimeError('An unrecognized account helper owns the socket; close it first.')
    return True


def recover_account_socket():
    """Recover only a dead, recorded helper's private, non-listening socket."""
    if account_pid():
        return
    recorded_dead = False
    for state, expected in ((STATE, HELPER), (ROOT / 'runtime/helper-session.json', OLD_HELPER)):
        try:
            data = json.loads(state.read_text())
            pid = int(data['pid'])
            if pid <= 1 or data['executable'] != str(expected):
                continue
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                recorded_dead = True
            else:
                return
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if not recorded_dead:
        return
    try:
        before = SOCKET.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(before.st_mode) or before.st_uid != os.getuid() or before.st_mode & 0o077:
        return
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(1)
        if connection.connect_ex(str(SOCKET)) != errno.ECONNREFUSED:
            return
    try:
        after = SOCKET.lstat()
        if (before.st_dev, before.st_ino) == (after.st_dev, after.st_ino):
            SOCKET.unlink()
    except FileNotFoundError:
        pass


@contextlib.contextmanager
def account(game, market='CA'):
    process = None
    try:
        recover_account_socket()
        if not account_ready() and not account_pid():
            require(HELPER)
            print('Starting the account helper. Complete Microsoft sign-in if a window opens.', flush=True)
            STATE.parent.mkdir(parents=True, exist_ok=True)
            log_path = ROOT / 'logs/standalone/account.log'
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open('ab') as log:
                env = dict(os.environ, XODUS_LOG='off', RUST_LOG='off')
                process = subprocess.Popen([str(HELPER), '--serve', str(game), '--market', market],
                    cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
            STATE.write_text(json.dumps({'pid': process.pid, 'executable': str(HELPER)}) + '\n')
            STATE.chmod(0o600)
        deadline = time.monotonic() + 300
        while not account_ready():
            if (process and process.poll() is not None) or not account_pid():
                raise RuntimeError('Account helper stopped; see logs/standalone/account.log.')
            if time.monotonic() >= deadline:
                raise RuntimeError('Microsoft sign-in did not finish within five minutes. Launch again to retry.')
            time.sleep(0.25)
        yield
    finally:
        if process:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=8)
            recover_account_socket()
            try:
                if not os.path.lexists(SOCKET) and json.loads(STATE.read_text()).get('pid') == process.pid:
                    STATE.unlink()
            except (OSError, ValueError):
                pass


def require(path):
    if not path.is_file():
        raise RuntimeError('Missing required file: ' + str(path))


def wine_run(args, game, *, log=None, timeout=None, network_diagnostics=False):
    require(WINE / 'bin/wine')
    return subprocess.run([str(WINE / 'bin/wine'), *map(str, args)],
        cwd=game, env=environment(network_diagnostics=network_diagnostics), stdout=log, stderr=subprocess.STDOUT,
        timeout=timeout, check=True)


def map_drive(letter, directory):
    link = PREFIX / 'dosdevices' / (letter + ':')
    if link.is_symlink() and link.resolve() == directory.resolve():
        return
    if link.exists() or link.is_symlink():
        raise RuntimeError('Unexpected existing drive mapping: ' + str(link))
    link.symlink_to(directory.resolve(), target_is_directory=True)


def wait_for_idle_prefix():
    if not PREFIX.exists():
        return
    try:
        subprocess.run([str(WINE / 'bin/wineserver'), '-w'], env=environment(),
                       timeout=1, check=True)
    except subprocess.TimeoutExpired:
        raise RuntimeError('Close programs using the standalone prefix before updating its setup.')


def stop_setup_server():
    # Only called after this preparation acquired an idle, separate prefix.
    subprocess.run([str(WINE / 'bin/wineserver'), '-k'], env=environment())
    subprocess.run([str(WINE / 'bin/wineserver'), '-w'], env=environment(),
                   timeout=10, check=True)


def prerequisites(game):
    for path in (WINE / 'bin/wine', WINE / 'bin/wineserver',
                 WINE / 'lib/wine/x86_64-windows/xgameruntime.dll',
                 DXMT / 'x86_64-windows/d3d11.dll',
                 DXMT / 'x86_64-unix/winemetal.so',
                 ROOT / 'runtime/xgameruntime.dll.threading',
                 game / 'Minecraft.Windows.exe', game / 'MicrosoftGame.Config',
                 game / '.xodus-streaming.msixvc',
                 game / 'Installers/GameInputRedist.msi'):
        require(path)
    # Wine 11.8 prefers installed builtins over WINEDLLPATH. Check the overlay,
    # so a later Wine rebuild cannot silently select its stock graphics DLLs.
    for relative in ('x86_64-windows/d3d11.dll', 'x86_64-windows/dxgi.dll',
                     'x86_64-windows/d3d10core.dll', 'x86_64-windows/winemetal.dll',
                     'x86_64-unix/winemetal.so'):
        installed = WINE / 'lib/wine' / relative
        require(installed)
        if relative == 'x86_64-unix/winemetal.so' and (WINE / 'dxmt-unix-bridge.json').exists():
            verify_unix_bridge()
            continue
        if sha256(installed) != sha256(DXMT / relative):
            raise RuntimeError('Reinstall DXMT with build-standalone-graphics.sh --wine-runtime ' + str(WINE))
    if sha256(ROOT / 'runtime/xgameruntime.dll.threading') != THREADING_HASH:
        raise RuntimeError('Microsoft threading DLL does not match the pinned official version.')
    with (game / 'Minecraft.Windows.exe').open('rb') as f:
        if f.read(2) != b'MZ':
            raise RuntimeError('Prepare the game with standalone-setup.py first.')


def verify_unix_bridge():
    """Check both halves of the optional locally rebuilt DXMT bridge."""
    try:
        metadata = json.loads((WINE / 'dxmt-unix-bridge.json').read_text())
        files = metadata['files']
        if metadata['version'] != 'v0.80' or metadata['source_commit'] != '589adb780354b461645b29999cefaf533594ee99':
            raise ValueError('unexpected DXMT source')
        if set(files) != {'winemetal.so', 'winemetal-upstream.so'}:
            raise ValueError('unexpected bridge file list')
        if files['winemetal-upstream.so'] != sha256(DXMT / 'x86_64-unix/winemetal.so'):
            raise ValueError('upstream graphics library changed')
        if metadata['patch_sha256'] != sha256(ROOT / 'patches/standalone-dxmt-memory-lifetime.patch'):
            raise ValueError('bridge patch changed')
        if metadata['trace_source_sha256'] != sha256(ROOT / 'standalone-dxmt-display-trace.c'):
            raise ValueError('bridge source changed')
        for name, expected in files.items():
            if sha256(WINE / 'lib/wine/x86_64-unix' / name) != expected:
                raise ValueError('installed bridge library changed')
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise RuntimeError('The rebuilt DXMT bridge failed verification. Rebuild and stage it again, or reinstall standard DXMT.') from error


def prepare(game):
    prerequisites(game)
    if PREFIX.is_symlink() or PREFIX.resolve() == (ROOT / 'bottles/Bedrock-Mac').resolve():
        raise RuntimeError('The standalone prefix must be a separate directory.')
    PREFIX.parent.mkdir(parents=True, exist_ok=True)
    logs = ROOT / 'logs/standalone'
    logs.mkdir(parents=True, exist_ok=True)
    marker = PREFIX / '.bedrock-setup.json'
    desired = {'setup_version': 2, 'game': str(game), 'threading': THREADING_HASH,
               'gameinput': sha256(game / 'Installers/GameInputRedist.msi'),
               'wine': sha256(WINE / 'bin/wine'),
               'dxmt': sha256(DXMT / 'x86_64-windows/d3d11.dll')}
    if marker.is_file() and json.loads(marker.read_text()) == desired:
        map_drive('g', game)
        map_drive('r', ROOT)
        return
    wait_for_idle_prefix()
    with (logs / 'prefix-setup.log').open('ab') as log:
        # Wine must create its own C: mapping before additional drives are added.
        wine_run(['wineboot', '-u'], game, log=log, timeout=180)
        map_drive('g', game)
        map_drive('r', ROOT)
        system32 = PREFIX / 'drive_c/windows/system32'
        system32.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / 'runtime/xgameruntime.dll.threading', system32)
        wine_run(['reg', 'import', 'R:\\winrt.reg'], game, log=log, timeout=60)
        wine_run(['reg', 'add', 'HKCU\\Software\\Wine', '/v', 'Version',
                  '/d', 'win10', '/f'], game, log=log, timeout=60)
        stop_setup_server()
        subprocess.run([sys.executable, str(ROOT / 'standalone-gameinput.py'),
                        '--prefix', str(PREFIX), '--msi', str(game / 'Installers/GameInputRedist.msi'),
                        '--wineserver', str(WINE / 'bin/wineserver')],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
        wine_run(['reg', 'import', 'R:\\bottles\\Bedrock-Standalone\\.standalone-gameinput.reg'],
                 game, log=log, timeout=60)
        stop_setup_server()
        subprocess.run([sys.executable, str(ROOT / 'standalone-gameinput.py'),
                        '--prefix', str(PREFIX), '--msi', str(game / 'Installers/GameInputRedist.msi'),
                        '--check'], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
    require(PREFIX / 'drive_c/Program Files/Microsoft GameInput/x64/GameInputRedist.dll')
    require(PREFIX / 'drive_c/Program Files/Microsoft GameInput/x64/GameInputRedistService.exe')
    marker.write_text(json.dumps(desired, indent=2) + '\n')


def game_running():
    processes = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
    return any(line.strip().lower().endswith('\\minecraft.windows.exe') for line in processes.splitlines())


def status(game):
    print('Wine runtime built:', (WINE / 'bin/wine').is_file())
    print('DXMT staged:', (DXMT / 'x86_64-unix/winemetal.so').is_file())
    print('Game present:', (game / 'Minecraft.Windows.exe').is_file())
    print('Standalone prefix prepared:', (PREFIX / '.bedrock-setup.json').is_file())
    print('Account service ready:', account_ready())
    print('Minecraft running:', game_running())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('check', 'prepare', 'probe', 'launch'))
    parser.add_argument('probe', nargs='?', choices=('graphics', 'account', 'store', 'privileges', 'claims'))
    parser.add_argument('--game-dir', type=Path, default=ROOT / 'game')
    parser.add_argument('--market', default='CA', help='Two-letter Store country code (default CA)')
    parser.add_argument('--network-diagnostics', action='store_true',
                        help='Log authentication results and HTTP host/status without credentials')
    args = parser.parse_args()
    if len(args.market) != 2 or not args.market.isascii() or not args.market.isalpha() or not args.market.isupper():
        parser.error('--market must be a two-letter uppercase country code')
    game = args.game_dir.expanduser().resolve()
    os.umask(0o077)
    if args.command == 'check':
        status(game)
        return 0
    if args.command == 'probe' and not args.probe:
        parser.error('probe requires graphics, account, store, privileges, or claims')
    if args.command == 'launch' and game_running():
        print('Minecraft is already running. Close it before testing the standalone launcher.')
        return 0
    lock_path = ROOT / 'runtime/standalone/launcher.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another standalone setup or game session is running.')
        prepare(game)
        if args.command == 'prepare':
            print('Standalone prefix prepared.')
            return 0
        if args.command == 'probe':
            names = {'graphics': 'standalone-graphics-probe.exe', 'account': 'runtime-auth-probe.exe',
                     'store': 'store-callback-probe.exe', 'privileges': 'runtime-privilege-probe.exe',
                     'claims': 'xuser-claims-test.exe'}
            location = ROOT / 'runtime/standalone/probes'
            require(location / names[args.probe])
            exe = 'R:\\runtime\\standalone\\probes\\' + names[args.probe]
            manager = account(game, args.market) if args.probe not in ('graphics', 'claims') else contextlib.nullcontext()
            with manager:
                wine_run([exe], game, timeout=90)
            return 0
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        log_path = ROOT / 'logs/standalone' / ('minecraft-' + stamp + '.log')
        print('Starting standalone Minecraft. Log: ' + str(log_path), flush=True)
        with account(game, args.market), log_path.open('wb') as log:
            wine_run(['G:\\Minecraft.Windows.exe'], game, log=log, network_diagnostics=args.network_diagnostics)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
