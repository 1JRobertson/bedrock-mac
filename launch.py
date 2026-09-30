#!/usr/bin/env python3
"""Launch the owned Windows game and its local account helper."""
from pathlib import Path
import datetime
import json
import os
import signal
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / 'sources/xodus/target/release/examples/bedrock_helper'
GAME = ROOT / 'game/Minecraft.Windows.exe'
STATE = ROOT / 'runtime/helper-session.json'
SOCKET = Path('/tmp/xodus.sock')


def helper_pid():
    try:
        data = json.loads(STATE.read_text())
        pid = int(data['pid'])
        if pid <= 1 or data['executable'] != str(HELPER):
            return None
        command = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
        path = Path(command)
        if not path.is_absolute():
            path = ROOT / path
        return pid if path.resolve() == HELPER else None
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
        return None


def ready():
    if not SOCKET.exists():
        return False
    info = SOCKET.stat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('The Xbox service socket has unexpected ownership or permissions.')
    if not helper_pid():
        raise RuntimeError('Another Xbox service owns the socket. Close it before launching this setup.')
    return True


def main():
    os.umask(0o077)
    for path in (HELPER, GAME, ROOT / 'run-windows.sh'):
        if not path.is_file():
            raise RuntimeError('Missing required file: ' + str(path))
    if '--check' in sys.argv:
        with GAME.open('rb') as f:
            prepared = f.read(2) == b'MZ'
        print('Game prepared:', prepared)
        print('Account helper running:', bool(helper_pid()))
        print('Account socket ready:', ready())
        return 0
    processes = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
    if any(line.strip().lower().endswith('\\minecraft.windows.exe') for line in processes.splitlines()):
        print('Minecraft is already running.')
        return 0
    (ROOT / 'logs').mkdir(exist_ok=True)
    helper = None
    try:
        if not ready() and not helper_pid():
            env = dict(os.environ, XODUS_LOG='off', RUST_LOG='off')
            with (ROOT / 'logs/bedrock-helper.log').open('ab') as log:
                helper = subprocess.Popen([str(HELPER), str(GAME.parent)], cwd=ROOT,
                    env=env, stdout=log, stderr=subprocess.STDOUT)
            STATE.write_text(json.dumps({'pid': helper.pid, 'executable': str(HELPER)}) + '\n')
            STATE.chmod(0o600)
        print('Preparing Minecraft. Complete Microsoft sign-in if a window opens.', flush=True)
        while not ready():
            if (helper and helper.poll() is not None) or not helper_pid():
                raise RuntimeError('The account helper stopped. See logs/bedrock-helper.log.')
            time.sleep(0.25)
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        log_path = ROOT / 'logs' / ('minecraft-' + stamp + '.log')
        print('Starting Minecraft. Log: ' + str(log_path), flush=True)
        with log_path.open('wb') as log:
            result = subprocess.run([str(ROOT / 'run-windows.sh'), str(GAME)], cwd=ROOT,
                stdout=log, stderr=subprocess.STDOUT)
        return result.returncode
    finally:
        if helper and helper.poll() is None:
            helper.send_signal(signal.SIGINT)
            try:
                helper.wait(timeout=8)
            except subprocess.TimeoutExpired:
                helper.terminate()
            if helper_pid() == helper.pid or helper.poll() is not None:
                STATE.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
