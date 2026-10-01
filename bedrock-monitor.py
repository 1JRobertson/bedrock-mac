#!/usr/bin/env python3
"""Local, read-only gameplay monitoring. Never signals or changes the game."""
import argparse
from collections import deque
import ctypes
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
DATA = ROOT / 'logs/standalone/monitor'
WINE = ROOT / 'runtime/standalone/wine'
LATEST = DATA / 'latest.json'
GIB = 1024 ** 3
INTERVAL = 10
WARNING = 6 * GIB
URGENT = 10 * GIB


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')


def stamp():
    return dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + str(os.getpid()) + '.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.chmod(0o600)
    os.replace(temporary, path)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def append_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as output:
        fcntl.flock(output, fcntl.LOCK_EX)
        output.write(json.dumps(data) + '\n')


def command(args, timeout=5):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL,
                                   timeout=timeout).strip()


class Usage(ctypes.Structure):
    # rusage_info_v2, from the installed macOS SDK's sys/resource.h.
    _fields_ = [('uuid', ctypes.c_ubyte * 16)] + [
        (name, ctypes.c_uint64) for name in (
            'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups',
            'pageins', 'wired_size', 'resident_size', 'phys_footprint',
            'proc_start_abstime', 'proc_exit_abstime', 'child_user_time',
            'child_system_time', 'child_pkg_idle_wkups', 'child_interrupt_wkups',
            'child_pageins', 'child_elapsed_abstime', 'diskio_bytesread',
            'diskio_byteswritten')]


def usage(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pid_rusage.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_void_p)
    library.proc_pid_rusage.restype = ctypes.c_int
    value = Usage()
    if library.proc_pid_rusage(pid, 2, ctypes.byref(value)):
        raise OSError(ctypes.get_errno(), 'Cannot read process memory')
    return {name: getattr(value, name) for name, _ in Usage._fields_ if name != 'uuid'}


def same_process(pid, birth):
    try:
        return usage(int(pid))['proc_start_abstime'] == birth
    except (OSError, ValueError, TypeError):
        return False


def owned_game(pid):
    # Windows process names alone do not distinguish this build from CrossOver.
    try:
        files = command(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'])
        return any(line.startswith('n' + str(WINE) + '/') for line in files.splitlines())
    except (OSError, subprocess.SubprocessError):
        return False


def find_games(known):
    found = []
    processes = command(['/bin/ps', '-axo', 'pid=,rss=,pcpu=,comm='])
    for line in processes.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4 or not fields[3].lower().endswith('\\minecraft.windows.exe'):
            continue
        pid = int(fields[0])
        try:
            measured = usage(pid)
        except OSError:
            continue
        key = (pid, measured['proc_start_abstime'])
        if key not in known and not owned_game(pid):
            continue
        found.append(dict(pid=pid, birth=key[1], cpu_percent=float(fields[2]),
                          rss_bytes=measured['resident_size'],
                          footprint_bytes=measured['phys_footprint'],
                          pageins=measured['pageins'],
                          read_bytes=measured['diskio_bytesread'],
                          written_bytes=measured['diskio_byteswritten']))
    return found


def system_memory():
    result = {}
    for key, args in (
        ('pressure_level', ['/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level']),
        ('swap', ['/usr/sbin/sysctl', '-n', 'vm.swapusage']),
        ('vm', ['/usr/bin/vm_stat']),
    ):
        try:
            result[key] = command(args)
        except (OSError, subprocess.SubprocessError) as error:
            result[key + '_error'] = str(error)
    if 'pressure_level' in result:
        result['pressure_level'] = int(result['pressure_level'])
    if 'swap' in result:
        match = re.search(r'used = ([\d.]+)M', result.pop('swap'))
        result['swap_used_bytes'] = int(float(match[1]) * 1024 ** 2) if match else None
    if 'vm' in result:
        raw = result.pop('vm')
        page = re.search(r'page size of (\d+) bytes', raw)
        size = int(page[1]) if page else 16384
        for name, label in (('compressed_bytes', 'Pages occupied by compressor'),
                            ('swapins', 'Swapins'), ('swapouts', 'Swapouts')):
            match = re.search(re.escape(label) + r':\s*(\d+)\.', raw)
            if match:
                result[name] = int(match[1]) * (size if name.endswith('_bytes') else 1)
    return result


def warnings(history, sample):
    """Thresholds identify reasons to inspect; growth alone does not prove a leak."""
    reasons = []
    footprint = sample['footprint_bytes']
    if footprint >= URGENT:
        reasons.append(('urgent-memory', 'Game memory is above 10 GB. Save and close Minecraft soon.'))
    elif footprint >= WARNING:
        reasons.append(('high-memory', 'Game memory is above 6 GB. Save your progress; memory is being checked.'))
    if sample.get('system', {}).get('pressure_level', 1) in (2, 4):
        reasons.append(('system-pressure', 'macOS reports memory pressure. Save your progress.'))
    # Ignore startup spikes. Compare approximately ten minutes of this one PID.
    older = [item for item in history if 480 <= sample['monotonic'] - item['monotonic'] <= 660]
    if sample.get('session_seconds', 0) >= 780 and older and footprint - older[-1]['footprint_bytes'] >= 512 * 1024 ** 2:
        reasons.append(('memory-growth', 'Game memory grew by at least 512 MB over about ten minutes.'))
    return reasons


def notify(message):
    script = 'on run argv\ndisplay notification (item 1 of argv) with title "Minecraft monitor"\nend run'
    try:
        subprocess.run(['/usr/bin/osascript', '-e', script, message], timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def event(kind, message, **details):
    item = dict(time=now(), id=stamp(), kind=kind, message=message, **details)
    append_json(DATA / 'events.jsonl', item)
    return item


def latest_game_log():
    logs = list((ROOT / 'logs/standalone').glob('minecraft-*.log'))
    return str(max(logs, key=lambda path: path.stat().st_mtime)) if logs else None


def crash_reports(pid, since):
    reports = []
    directory = Path.home() / 'Library/Logs/DiagnosticReports'
    for path in directory.glob('*.ips'):
        try:
            if path.stat().st_mtime < since:
                continue
            with path.open(errors='replace') as source:
                header = source.read(65536)
            if re.search(r'"pid"\s*:\s*' + str(pid) + r'\b', header):
                reports.append(str(path))
        except OSError:
            continue
    return reports


def capture(reason, games):
    directory = DATA / 'incidents' / stamp()
    directory.mkdir(parents=True, exist_ok=False)
    result = dict(time=now(), reason=reason, processes=games,
                  game_log=latest_game_log(), system=system_memory(), diagnostics=[])
    for game in games:
        pid = game['pid']
        if not same_process(pid, game['birth']) or not owned_game(pid):
            continue
        for name, args, diagnostic in (
            ('memory.txt', ['/usr/bin/vmmap', '-summary', str(pid)], directory / f'{pid}-memory.txt'),
            ('sample-command.txt', ['/usr/bin/sample', str(pid), '1', '10', '-file', str(directory / f'{pid}-threads.txt')], directory / f'{pid}-threads.txt'),
        ):
            output = directory / f'{pid}-{name}'
            try:
                with output.open('w') as destination:
                    completed = subprocess.run(args, stdout=destination, stderr=subprocess.STDOUT, timeout=12)
                result['diagnostics'].append(dict(path=str(diagnostic), command_output=str(output),
                                                  exit_code=completed.returncode, exists=diagnostic.is_file()))
            except (OSError, subprocess.SubprocessError) as error:
                result['diagnostics'].append(dict(path=str(output), error=str(error)))
    atomic_json(directory / 'incident.json', result)
    return str(directory)


def monitor_alive(state=None):
    state = state or read_json(LATEST)
    pid, birth = state.get('monitor_pid'), state.get('monitor_birth')
    if not pid or not birth or not same_process(pid, birth):
        return False
    try:
        args = command(['/bin/ps', '-p', str(pid), '-o', 'args='])
        return str(Path(__file__).resolve()) in args and 'watch' in args.split()
    except (OSError, subprocess.SubprocessError):
        return False


def watch():
    DATA.mkdir(parents=True, exist_ok=True)
    with (DATA / 'monitor.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        os.nice(10)
        running = True

        def stop_signal(_signum, _frame):
            nonlocal running
            running = False

        signal.signal(signal.SIGTERM, stop_signal)
        signal.signal(signal.SIGINT, stop_signal)
        birth = usage(os.getpid())['proc_start_abstime']
        state = dict(monitor_pid=os.getpid(), monitor_birth=birth, started_at=now(),
                     interval_seconds=INTERVAL, status='waiting', games=[],
                     warning_bytes=WARNING, urgent_bytes=URGENT)
        sessions, recent_alerts, pending_exits, pressure_count = {}, {}, [], 0
        event('monitor-started', 'Background sampling started.')
        try:
            while running:
                try:
                    games = find_games(sessions)
                    memory = system_memory()
                    pressure_count = pressure_count + 1 if memory.get('pressure_level') in (2, 4) else 0
                    live = {(item['pid'], item['birth']) for item in games}
                    for key in list(sessions):
                        if key in live:
                            continue
                        session = sessions.pop(key)
                        event('game-ended', 'The game process exited.', pid=key[0],
                              samples=str(session['path']))
                        pending_exits.append(dict(pid=key[0], since=session['wall_start'],
                                                  exited=time.monotonic()))
                        for alert_key in list(recent_alerts):
                            if alert_key[0] == key:
                                del recent_alerts[alert_key]
                    # DiagnosticReports can arrive several seconds after process exit.
                    for ended in pending_exits[:]:
                        reports = crash_reports(ended['pid'], ended['since'])
                        if reports:
                            alert = event('crash', 'macOS recorded a game crash.',
                                          pid=ended['pid'], crash_reports=reports)
                            notify(alert['message'])
                        if reports or time.monotonic() - ended['exited'] >= 120:
                            pending_exits.remove(ended)
                    for game in games:
                        key = (game['pid'], game['birth'])
                        if key not in sessions:
                            directory = DATA / 'sessions' / (stamp() + '-' + str(game['pid']))
                            directory.mkdir(parents=True)
                            sessions[key] = dict(path=directory / 'samples.jsonl',
                                                 history=deque(maxlen=90), wall_start=time.time(), peak=0)
                            event('game-started', 'Standalone Minecraft detected.', pid=game['pid'],
                                  samples=str(sessions[key]['path']), game_log=latest_game_log())
                        session = sessions[key]
                        sample = dict(time=now(), monotonic=time.monotonic(), system=memory,
                                      session_seconds=round(time.time() - session['wall_start']), **game)
                        append_json(session['path'], sample)
                        for kind, message in warnings(session['history'], sample):
                            if kind == 'system-pressure' and pressure_count < 3:
                                continue
                            alert_key = (key, kind)
                            if time.monotonic() - recent_alerts.get(alert_key, -1000) < 600:
                                continue
                            recent_alerts[alert_key] = time.monotonic()
                            delivered = notify(message)
                            report = capture(message, [game])
                            event(kind, message, pid=game['pid'], footprint_bytes=game['footprint_bytes'],
                                  incident=report, notification_requested=delivered)
                        session['history'].append(sample)
                        game['samples'] = str(session['path'])
                        session['peak'] = max(session['peak'], game['footprint_bytes'])
                        game['peak_footprint_bytes'] = session['peak']
                    state.update(updated_at=now(), status='playing' if games else 'waiting',
                                 games=games, system=memory, last_error=None)
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    state.update(updated_at=now(), status='monitor-error', last_error=str(error))
                atomic_json(LATEST, state)
                for _ in range(INTERVAL * 4):
                    if not running:
                        break
                    time.sleep(0.25)
        finally:
            state.update(updated_at=now(), status='stopped', games=[])
            atomic_json(LATEST, state)
            event('monitor-stopped', 'Background sampling stopped.')
    return 0


def start():
    if monitor_alive():
        return
    DATA.mkdir(parents=True, exist_ok=True)
    with (DATA / 'background.log').open('ab') as log:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'watch'],
                                   cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True, close_fds=True)
    for _ in range(40):
        if monitor_alive():
            print('Minecraft monitor is running. Samples every 10 seconds.', flush=True)
            return
        if process.poll() is not None:
            break
        time.sleep(0.1)
    raise RuntimeError('Monitor did not start; check logs/standalone/monitor/background.log.')


def mark(note):
    state = read_json(LATEST)
    if not monitor_alive(state):
        raise RuntimeError('The monitor is not running. Launch Standalone.command starts it.')
    games = state.get('games', [])
    incident = capture(note, games)
    event('player-report', note, incident=incident)
    print('Problem marked. Diagnostics: ' + incident)


def status():
    state = read_json(LATEST)
    state['monitor_alive'] = monitor_alive(state)
    # Read a bounded tail; never read account credentials or dump game logs.
    path = DATA / 'events.jsonl'
    if path.exists():
        with path.open('rb') as source:
            source.seek(max(0, path.stat().st_size - 32768))
            lines = source.read().decode(errors='replace').splitlines()
        events = []
        for line in lines:
            try:
                events.append(json.loads(line))
            except ValueError:
                continue
        state['recent_events'] = events[-12:]
    print(json.dumps(state, indent=2))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('start', 'watch', 'status', 'mark', 'stop', 'play'))
    parser.add_argument('details', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command == 'watch':
        return watch()
    if args.command == 'start':
        start()
    elif args.command == 'status':
        status()
    elif args.command == 'mark':
        mark(' '.join(args.details) or 'Player noticed a problem; inspect the matching timestamp.')
    elif args.command == 'stop':
        state = read_json(LATEST)
        if monitor_alive(state):
            os.kill(state['monitor_pid'], signal.SIGTERM)
            print('Stopping the monitor. Minecraft continues running.')
        else:
            print('Monitor is already stopped.')
    elif args.command == 'play':
        start()
        forwarded = args.details[1:] if args.details[:1] == ['--'] else args.details
        started = event('launch-requested', 'Starting the regular standalone launcher.')
        code = subprocess.call([sys.executable, str(ROOT / 'standalone.py'), 'launch', *forwarded], cwd=ROOT)
        event('launcher-exited', 'Standalone launcher exited.', exit_code=code, launch_id=started['id'])
        if code:
            incident = capture('Standalone launcher exited with an error.', [])
            event('launch-error', 'Standalone launcher exited with an error.',
                  exit_code=code, incident=incident, launch_id=started['id'])
            notify('Minecraft exited with an error. Diagnostics are available in this chat.')
        return code
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
