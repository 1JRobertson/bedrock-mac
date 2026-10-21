#!/usr/bin/env python3
"""Observe one owned, isolated game; never launch, stop, or alter a process."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

BASE = Path(__file__).resolve().parent


def process(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,time=,%cpu=,rss=,state=,command='],
                            capture_output=True, text=True, timeout=5)
    fields = result.stdout.strip().split(None, 9)
    if result.returncode or len(fields) < 10:
        return None
    # lstart has five fields; TIME, CPU, RSS, state follow it.
    return {'identity': ' '.join(fields[:5]), 'cpu_time': fields[5],
            'cpu_percent': float(fields[6]), 'rss_mib': int(fields[7])/1024,
            'state': fields[8], 'command': ' '.join(fields[9:])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--minutes', type=float, default=85)
    args = parser.parse_args()
    first = process(args.pid)
    expected = str(BASE / 'game/Minecraft.Windows.exe').replace('/', '\\')
    if not first or expected not in first['command']:
        raise RuntimeError('PID is not the isolated Minecraft process')
    os.umask(0o077)
    folder = BASE / 'logs/soak' / time.strftime('%Y%m%d-%H%M%S')
    folder.mkdir(parents=True)
    start = time.monotonic()
    report = {'pid': args.pid, 'start_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'identity': first['identity'], 'status': 'observing; active ticks need visual verification',
              'samples': 0, 'peak_rss_mib': 0}
    # Keep only this PID's Metal HUD telemetry. The observer owns and cleans its reader.
    with (folder/'metal-hud.ndjson').open('w') as hud, (folder/'process.ndjson').open('w') as samples:
        reader = subprocess.Popen(['/usr/bin/log', 'stream', '--style', 'ndjson', '--level', 'debug',
                                   '--process', str(args.pid), '--predicate',
                                   'subsystem == "com.apple.metal.hud"', '--timeout', '90m'],
                                  stdout=hud, stderr=subprocess.DEVNULL)
        try:
            while True:
                elapsed = time.monotonic()-start
                current = process(args.pid)
                if not current or current['identity'] != first['identity']:
                    report['status'] = 'process exited or identity changed'
                    break
                current.pop('command')
                sample = {'elapsed_s': round(elapsed, 1), **current}
                guard = BASE / 'logs/game-host-memory-latest.json'
                if guard.exists():
                    sample['host_memory'] = json.loads(guard.read_text())
                with (BASE/'logs/game-compat-relaxed.log').open('rb') as log:
                    log.seek(0, 2)
                    log.seek(max(0, log.tell()-65536))
                    tail = log.read().decode(errors='replace')
                sample['crash_signature'] = any(s in tail for s in
                    ('Unhandled page fault', 'GPU fault', 'DeviceRemoved', 'device lost'))
                samples.write(json.dumps(sample)+'\n')
                samples.flush()
                report['samples'] += 1
                report['elapsed_s'] = sample['elapsed_s']
                report['peak_rss_mib'] = round(max(report['peak_rss_mib'], sample['rss_mib']), 1)
                report['latest'] = sample
                (folder/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
                if report['samples'] % 4 == 1:
                    print(json.dumps({'folder':str(folder), **sample}), flush=True)
                if sample['crash_signature']:
                    report['status'] = 'crash signature; investigate before continuing'
                    break
                if elapsed >= args.minutes*60:
                    report['status'] = 'observation window ended; active ticks and final scene need verification'
                    break
                time.sleep(15)
        finally:
            reader.terminate()
            try:
                reader.wait(timeout=5)
            except subprocess.TimeoutExpired:
                reader.kill()
                reader.wait()
            report['end_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
            (folder/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'folder': str(folder), 'status': report['status']}))


if __name__ == '__main__':
    main()
