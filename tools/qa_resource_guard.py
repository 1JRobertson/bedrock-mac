"""Run one bounded QA job; refuse unsafe host memory and keep output on disk."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / 'work/qa-resource-guard'


def snapshot():
    pressure = int(subprocess.check_output(
        ['sysctl', '-n', 'kern.memorystatus_vm_pressure_level'], text=True, timeout=5).strip())
    swap = subprocess.check_output(['sysctl', 'vm.swapusage'], text=True, timeout=5)
    used = re.search(r'used\s*=\s*([\d.]+)M', swap)
    if not used:
        raise RuntimeError('Cannot verify system swap usage')
    processes = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=5)
    app_ids = {int(line.split(None, 1)[0]) for line in processes.splitlines()
               if '/Applications/ChatGPT.app/' in line}
    table = subprocess.check_output(
        ['top', '-l', '1', '-n', '256', '-o', 'mem', '-stats', 'pid,command,mem'],
        text=True, timeout=8)
    app_bytes = 0
    for line in table.splitlines():
        match = re.match(r'^\s*(\d+)\s+.+?\s+([\d.]+)([BKMGT])[-+]?\s*$', line)
        if match and int(match[1]) in app_ids:
            app_bytes += float(match[2]) * 1024 ** 'BKMGT'.index(match[3])
    if app_ids and not app_bytes:
        raise RuntimeError('Cannot verify app memory footprint')
    return {'pressure_level': pressure, 'swap_mib': float(used[1]),
            'app_footprint_mib': round(app_bytes / 1024 ** 2, 1), 'time': time.time()}


def problems(sample):
    return ([f"macOS memory pressure level {sample['pressure_level']}" ]
            if sample['pressure_level'] != 1 else []) + (
        ['swap exceeds 8 GiB'] if sample['swap_mib'] >= 8192 else []) + (
        ['app footprint exceeds 8 GiB'] if sample['app_footprint_mib'] >= 8192 else [])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--status', action='store_true')
    parser.add_argument('--log', type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    STATE.mkdir(parents=True, exist_ok=True)
    sample = snapshot()
    (STATE / 'latest.json').write_text(json.dumps(sample, indent=2) + '\n')
    if args.status:
        print(json.dumps({**sample, 'blocked_by': problems(sample)}))
        return int(bool(problems(sample)))
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not args.log:
        parser.error('Use --log /path/to/log -- command arguments')
    with (STATE / 'heavy-job.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another guarded heavy QA job is running')
        if problems(sample):
            raise RuntimeError('QA refused: ' + '; '.join(problems(sample)))
        args.log.parent.mkdir(parents=True, exist_ok=True)
        with args.log.open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                while process.poll() is None:
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        sample = snapshot()
                        (STATE / 'latest.json').write_text(json.dumps(sample, indent=2) + '\n')
                        if problems(sample):
                            raise RuntimeError('QA stopped: ' + '; '.join(problems(sample)))
            finally:
                if process.poll() is None:
                    # Only the process group started by this guard; never the desktop app.
                    os.killpg(process.pid, signal.SIGINT)
                    try:
                        process.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
        print(json.dumps({'exit_code': process.returncode, 'log': str(args.log)}))
        return process.returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(75)
