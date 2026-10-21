#!/usr/bin/env python3
"""Build/set/status/decode the optional frame-slab experiment's control file.

Build the native atomic writer before measurements. During an explicitly enabled
isolated game session, use `set --control FILE --chunk-kib 0|4|16|64`. Settings
apply when a frame registers; prior frames retain their original storage until
retirement. `status --control FILE` reads only individual atomic header gauges;
those readings do not form a coherent snapshot. `decode --control FILE` refuses
a live mapping and reads the complete per-thread capture only after exit.
This tool does not launch a game, modify its executable, or stage a runtime.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/bedrock-frame-control'
MAGIC = 0x3142414c53465242
HEADER = ('magic version size requested_chunk applied_chunk frames_registered frames_retired '
          'frames_unregistered closed quarantined registered_threads overflow_threads '
          'reserved peak refills live_scopes').split()
COUNTERS = 'calls hits bytes fallbacks tasks leased_tasks exceptions'.split()
THREADS = 512
ROW_STRIDE = 128
SIZE = 8 * len(HEADER) + THREADS * ROW_STRIDE
MAX_RESERVED = 384 * 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def no_symlinks(path):
    path = Path(path).absolute()
    for part in (path, *path.parents):
        if part.is_symlink():
            raise RuntimeError('Refusing symlink path')
    return path


def validate_header(data, header_only=False):
    if len(data) != (128 if header_only else SIZE):
        raise RuntimeError('Incorrect frame-control file size')
    header = dict(zip(HEADER, struct.unpack_from('<16Q', data)))
    if (header['magic'], header['version'], header['size']) != (MAGIC, 1, SIZE):
        raise RuntimeError('Unsupported or uninitialized frame-control header')
    if header['registered_threads'] > THREADS:
        raise RuntimeError('Invalid registered-thread count')
    if header['requested_chunk'] not in (0, 4096, 16384, 65536):
        raise RuntimeError('Invalid requested chunk size')
    if header['applied_chunk'] not in (0, 4096, 16384, 65536):
        raise RuntimeError('Invalid applied chunk size')
    return header


def require_closed(path):
    lsof = shutil.which('lsof') or ('/usr/sbin/lsof' if Path('/usr/sbin/lsof').exists() else None)
    if not lsof:
        raise RuntimeError('lsof is required to verify the capture is no longer mapped')
    result = subprocess.run([lsof, '-Fp', '--', str(path)], text=True, capture_output=True)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError('Could not establish whether the control file is still mapped')
    if any(line.startswith('p') for line in result.stdout.splitlines()):
        raise RuntimeError('Control file is still in use; decode only after the experiment exits')


def decode(path):
    path = no_symlinks(path)
    # The valid header is published only after mapping. Check it before lsof so
    # a file still being created cannot pass a premature no-holder check.
    if path.stat().st_size != SIZE:
        raise RuntimeError('Incorrect frame-control file size')
    with path.open('rb') as stream:
        validate_header(stream.read(128), header_only=True)
    require_closed(path)
    data = path.read_bytes()
    header = validate_header(data)
    if header['reserved'] > MAX_RESERVED or header['peak'] > MAX_RESERVED:
        raise RuntimeError('Recorded slab memory exceeds the configured bound')
    totals = dict.fromkeys(COUNTERS, 0)
    for at in range(header['registered_threads']):
        values = struct.unpack_from('<7Q', data, 128 + at * ROW_STRIDE)
        for name, value in zip(COUNTERS, values):
            totals[name] += value
    if totals['hits'] + totals['fallbacks'] != totals['calls'] or totals['leased_tasks'] > totals['tasks']:
        raise RuntimeError('Inconsistent completed per-thread counters')
    return dict(format=1, capture_sha256=sha(data), decoded_after_exit=True,
                requested_chunk_bytes=header['requested_chunk'], applied_chunk_bytes=header['applied_chunk'],
                frames={key: header[key] for key in ('frames_registered', 'frames_retired', 'frames_unregistered', 'closed', 'quarantined')},
                memory={'reserved_bytes': header['reserved'], 'sum_pool_peak_bytes': header['peak'],
                        'maximum_reserved_bytes': MAX_RESERVED, 'refills': header['refills'],
                        'live_scopes': header['live_scopes']},
                registered_threads=header['registered_threads'], overflow_threads=header['overflow_threads'],
                complete_thread_coverage=header['overflow_threads'] == 0, totals=totals)


def build(out, compiler):
    out = no_symlinks(out)
    source = ROOT / 'experiments/frame-slab-control.c'
    binary = no_symlinks(out / 'frame-slab-control')
    metadata = no_symlinks(out / 'manifest.json')
    compiler = shutil.which(compiler)
    if not compiler:
        raise RuntimeError('Native C compiler unavailable')
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(binary)], check=True)
    metadata.write_text(json.dumps({'format': 1, 'source_sha256': sha(source.read_bytes()),
                                    'binary_sha256': sha(binary.read_bytes()), 'control_version': 1}, indent=2) + '\n')
    print('Built atomic frame controller:', binary)


def run_control(out, control, operation):
    out, control = no_symlinks(out), no_symlinks(control)
    binary = no_symlinks(out / 'frame-slab-control')
    metadata = json.loads(no_symlinks(out / 'manifest.json').read_bytes())
    if (metadata.get('format') != 1 or metadata.get('control_version') != 1 or
            metadata.get('source_sha256') != sha((ROOT / 'experiments/frame-slab-control.c').read_bytes()) or
            metadata.get('binary_sha256') != sha(binary.read_bytes())):
        raise RuntimeError('Controller source/binary changed; explicitly rebuild it before measurement')
    if operation not in ('0', '4', '16', '64', 'status'):
        raise RuntimeError('Unsupported control operation')
    return subprocess.run([str(binary), str(control), operation], check=True)


def set_chunk(out, control, chunk):
    if chunk not in (0, 4, 16, 64):
        raise RuntimeError('Unsupported chunk size')
    return run_control(out, control, str(chunk))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('build')
    p.add_argument('--output', type=Path, default=OUT)
    p.add_argument('--compiler', default='cc')
    p = sub.add_parser('set')
    p.add_argument('--output', type=Path, default=OUT, help='Directory containing the built controller')
    p.add_argument('--control', type=Path, required=True)
    p.add_argument('--chunk-kib', type=int, choices=(0, 4, 16, 64), required=True)
    p = sub.add_parser('status')
    p.add_argument('--output', type=Path, default=OUT, help='Directory containing the built controller')
    p.add_argument('--control', type=Path, required=True)
    p = sub.add_parser('decode')
    p.add_argument('--control', type=Path, required=True)
    p.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.command == 'build':
        build(args.output, args.compiler)
    elif args.command == 'set':
        set_chunk(args.output, args.control, args.chunk_kib)
    elif args.command == 'status':
        run_control(args.output, args.control, 'status')
    else:
        text = json.dumps(decode(args.control), indent=2, sort_keys=True) + '\n'
        if args.output:
            output = no_symlinks(args.output)
            if output == no_symlinks(args.control):
                raise RuntimeError('Refusing to overwrite control capture')
            output.write_text(text)
        else:
            print(text, end='')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
