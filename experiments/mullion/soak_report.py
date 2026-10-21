#!/usr/bin/env python3
"""Summarize native Metal HUD rows for one recorded soak; never infer PASS."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import statistics

BASE = Path(__file__).resolve().parent
HUD = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+).* metal-HUD: (.*)$')


def percentile(values, p):
    values = sorted(values)
    return values[min(len(values)-1, int((len(values)-1)*p))] if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session', type=Path)
    args = parser.parse_args()
    session = args.session.resolve()
    if not session.is_relative_to(BASE/'logs/soak'):
        raise RuntimeError('Session must belong to this experiment')
    start = json.loads((session/'start.json').read_text())
    source = session/'game.log'
    if not source.exists():
        source = BASE/'logs/game-compat-relaxed.log'
    if source.stat().st_size > 64*1024**2:
        raise RuntimeError('Unexpectedly large input; inspect before parsing')
    end = json.loads((session/'end.json').read_text()).get('ended_unix', float('inf')) if (session/'end.json').exists() else float('inf')
    rows, intervals, gpu = [], [], []
    for line in source.read_text(errors='replace').splitlines():
        match = HUD.match(line)
        if not match:
            continue
        stamp = datetime.strptime(match[1], '%Y-%m-%d %H:%M:%S.%f').timestamp()
        if stamp < start['started_unix'] or stamp > end:
            continue
        try:
            values = list(map(float, match[2].split(',')))
        except ValueError:
            continue
        if len(values) < 5 or (len(values)-3) % 2:
            continue
        present, times = values[3::2], values[4::2]
        intervals.extend(x for x in present if x > 0)
        gpu.extend(x for x in times if x >= 0)
        rows.append({'time':stamp, 'frame':int(values[0]), 'graphics_mib':values[1],
                     'process_mib':values[2], 'frames':len(present)})
    if not rows:
        print(json.dumps({'status':'no post-start HUD samples'}))
        return
    latest = [x for x in rows if x['time'] >= rows[-1]['time']-60]
    windows = {}
    for row in rows:
        minute = int((row['time'] - start['started_unix']) // 60)
        windows.setdefault(minute, []).append(row)
    window_summary = [{'minute':minute, 'samples':len(group),
                       'median_graphics_mib':round(statistics.median(x['graphics_mib'] for x in group),2),
                       'median_process_mib':round(statistics.median(x['process_mib'] for x in group),2),
                       'presented_frames':sum(x['frames'] for x in group)}
                      for minute, group in sorted(windows.items())]
    report = {'status':'telemetry only; active ticks and final scene require verification',
              'hud_seconds':len(rows), 'wall_minutes':round((rows[-1]['time']-rows[0]['time'])/60,2),
              'presented_frames':len(intervals),
              'mean_present_fps':round(1000*len(intervals)/sum(intervals),2) if intervals else None,
              'median_present_ms':round(statistics.median(intervals),2) if intervals else None,
              'p95_present_ms':percentile(intervals,.95),
              'median_gpu_ms':round(statistics.median(gpu),2) if gpu else None,
              'graphics_mib':{'first':rows[0]['graphics_mib'], 'last':rows[-1]['graphics_mib'],
                              'peak':max(x['graphics_mib'] for x in rows)},
              'process_mib':{'first':rows[0]['process_mib'], 'last':rows[-1]['process_mib'],
                             'peak':max(x['process_mib'] for x in rows)},
              'last_minute_frames':sum(x['frames'] for x in latest),
              'last_frame_number':rows[-1]['frame']}
    report['minute_windows'] = window_summary
    (session/'performance.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k != 'minute_windows'}))


if __name__ == '__main__':
    main()
