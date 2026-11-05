#!/usr/bin/env python3
"""Run the real D3D readback fixture against both research renderers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import time

from build_renderer import HERE, run, sha


def wait(check, source, worker, label, seconds=60):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        if source.poll() is not None or worker.poll() is not None:
            raise RuntimeError('An endpoint exited at ' + label)
        time.sleep(.02)
    raise TimeoutError(label)


def token(path):
    with path.open('xb') as stream:
        stream.write(b'arm\n')


def ready(frame, pid):
    with (frame / 'chunk-stream.bin').open('rb') as file:
        data = file.read(1032)
    return (len(data) == 1032 and
            struct.unpack_from('<QII', data) == (0x4244434853483031, 1, 65536) and
            struct.unpack_from('<Q', data, 256)[0] == pid and
            struct.unpack_from('<Q', data, 384)[0] == 0 and
            struct.unpack_from('<Q', data, 1024)[0] == 1)


def capture(frame, target):
    from PIL import Image

    status = frame / 'offscreen-snapshot.json'
    path = frame / 'offscreen-snapshot.png'
    if not status.is_file() or not path.is_file():
        return None
    try:
        record = json.loads(status.read_text())
    except json.JSONDecodeError:
        return None
    if record.get('status') != 'captured' or record.get('gpu_completed') != 1:
        return None
    with Image.open(path) as image:
        if image.size != (64, 64):
            raise ValueError('Unexpected image extent')
        rgba = image.convert('RGBA').tobytes()
    status.unlink()
    path.replace(target)
    return {'green_pixels': sum(rgba[i+1] >= 250 and rgba[i] < 5 and rgba[i+2] < 5
                                for i in range(0, len(rgba), 4)),
            'rgba_sha256': hashlib.sha256(rgba).hexdigest()}


def stop(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def verify_mappings(process, wine, expected):
    names = subprocess.check_output(['/usr/sbin/lsof', '-a', '-p', str(process.pid), '-Fn'],
                                    text=True, timeout=10)
    found = set()
    for line in names.splitlines():
        path = Path(line[1:])
        if line.startswith('n') and path.name in expected and path.is_file():
            if sha(path) != expected[path.name] or not path.is_relative_to(wine.parent):
                raise ValueError('Unexpected loaded module: ' + path.name)
            found.add(path.name)
    if found != set(expected):
        raise ValueError('Missing loaded modules: ' + ', '.join(sorted(set(expected) - found)))


def verify_build(build, mode):
    receipt = json.loads((build / 'renderer.json').read_text())
    if receipt['mode'] != mode:
        raise ValueError('Incorrect renderer mode: ' + mode)
    for name in ('winemetal.so', 'winemetal-upstream.so', 'd3d11.dll', 'winemetal.dll',
                 'worker/native-draw-executor'):
        if sha(build / name) != receipt['files'][name]:
            raise ValueError('Build identity changed: ' + name)
    return receipt


def renderer_environment(base, frame, mode):
    common = dict(base, BEDROCK_FULLFRAME_CHUNK_STREAM=str(frame / 'chunk-stream.bin'),
                  BEDROCK_FULLFRAME_READBACK_STREAM=str(frame / 'readback-stream.bin'),
                  BEDROCK_NATIVE_BUFFER_REF_EXPERIMENT='1',
                  BEDROCK_NATIVE_RETAINED='1', BEDROCK_PRIVATE_RETAINED_OBSERVER='0',
                  BEDROCK_NATIVE_SOURCE_TIMELINE='1', BEDROCK_NATIVE_REPLAY_ROW_CACHE='1',
                  BEDROCK_PRIVATE_PACKED_REPLAY='2', BEDROCK_NATIVE_SNAPSHOT_BATCH='1',
                  BEDROCK_SOURCE_STAGING_POOL='1', BEDROCK_NATIVE_UPLOAD_POOL='1',
                  BEDROCK_NATIVE_RESOURCE_DESCRIPTORS='1', BEDROCK_SOURCE_SCALAR_REFERENCES='1',
                  BEDROCK_NATIVE_VERTEX_ROLE_INDEX='2', BEDROCK_LIVE_COMMANDS=str(int(mode == 'direct')),
                  BEDROCK_DIRECT_PASS=str(int(mode == 'direct')),
                  BEDROCK_DIRECT_UPLOAD='2' if mode == 'direct' else '0')
    we = dict(common,               DXMT_FRAME_STREAM='1', DXMT_CHUNK_STREAM='1', DXMT_NATIVE_COMPLETION='1',
              DXMT_NATIVE_RENDER='1', BEDROCK_FULLFRAME_FRAME_STREAM_DIRECTORY=str(frame),
              BEDROCK_FULLFRAME_DRAW_DIR=str(frame), BEDROCK_FULLFRAME_DRAW_CUT_DIR=str(frame),
              BEDROCK_FULLFRAME_IA_TRACK='1', DXMT_SHADER_CACHE='0',
              BEDROCK_FULLFRAME_DRAW_REPLAY='1', BEDROCK_FULLFRAME_DRAW_PASS='1',
              BEDROCK_FULLFRAME_TYPED_METADATA='1')
    return common, we


def case(output, mode, build, runtime, fixture, base):
    verify_build(build, mode)
    output.mkdir(mode=0o700)
    wine, prefix, frame, gates = (output / name for name in ('wine', 'prefix', 'frame', 'gates'))
    for path in (prefix, frame, gates):
        path.mkdir(mode=0o700)
    run('/bin/cp', '-cR', runtime, wine, timeout=120)
    expected = {}
    for folder, names in (('x86_64-unix', ('winemetal.so', 'winemetal-upstream.so')),
                          ('x86_64-windows', ('d3d11.dll', 'winemetal.dll'))):
        parent = wine / 'lib/wine' / folder
        if parent.resolve() != parent:
            raise ValueError('Linked staging directory')
        for name in names:
            dest = parent / name
            dest.unlink(missing_ok=True)
            shutil.copyfile(build / name, dest)
            if name != 'winemetal-upstream.so':
                expected[name] = sha(dest)
    expected['dxgi.dll'] = sha(wine / 'lib/wine/x86_64-windows/dxgi.dll')
    native = build / 'worker/native-draw-executor'
    for option, name in (('--initialize-chunk-stream', 'chunk-stream.bin'),
                         ('--initialize-readback-stream', 'readback-stream.bin')):
        run(native, option, frame / name, env=base, timeout=15)
    common, we = renderer_environment(base, frame, mode)
    ne = dict(common, BEDROCK_FULLFRAME_DRAW_PRESENT_SECONDS='180', BEDROCK_NATIVE_OFFSCREEN='1',
              BEDROCK_RETAINED_FIXTURE_DIAGNOSTICS='1')
    we.update(WINEPREFIX=str(prefix), WINEARCH='win64', WINEDEBUG='-all',
              BEDROCK_NATIVE_OFFSCREEN='1',
              WINEDLLOVERRIDES='mscoree,mshtml=;winemenubuilder.exe=d;d3d11,dxgi,d3d10core,winemetal=b')
    source = worker = None
    source_log = output / 'source.log'
    native_log = output / 'native.log'
    results = []
    try:
        with source_log.open('wb') as so, native_log.open('wb') as no:
            worker = subprocess.Popen([native, '--directory', frame, '--timeout', '180'],
                                      env=ne, cwd=output, stdout=no, stderr=subprocess.STDOUT)
            source = subprocess.Popen([wine / 'bin/wine', fixture, 'Z:' + str(gates).replace('/', '\\')],
                                      env=we, cwd=output, stdout=so, stderr=subprocess.STDOUT)
            def gate(label):
                return 'GATE ' + label in source_log.read_text(errors='replace').splitlines()

            wait(lambda: gate('warm'), source, worker, 'warmup')
            verify_mappings(source, wine, expected)
            token(frame / 'frame.arm')
            wait(lambda: ready(frame, worker.pid), source, worker, 'native arm')
            steps = [('begin', 'first', 4096), ('mutate', 'final', 0)] + [
                ('finish' if n == 0 else f'next{n-1}', f'step{n}', 4096 if n % 2 == 0 else 0)
                for n in range(6)]
            for release, label, green in steps:
                token(frame / 'offscreen-snapshot.request')
                start = time.monotonic()
                (gates / release).touch(exist_ok=False)
                wait(lambda: gate(label), source, worker, label)
                row = wait(lambda: capture(frame, output / (label + '.png')), source, worker, label)
                row.update(label=label, gate_to_readback_ms=round((time.monotonic()-start)*1000, 2))
                if row['green_pixels'] != green:
                    raise ValueError('Unexpected native pixels at ' + label)
                results.append(row)
            (gates / 'next5').touch(exist_ok=False)
            if source.wait(timeout=25) or worker.wait(timeout=25):
                raise RuntimeError('Fixture did not retire successfully')
        if 'RETAINED_D3D_COMPLETE' not in source_log.read_text(errors='replace'):
            raise ValueError('Fixture did not report completion')
        counts = re.findall(r'\[live-command-native\] payloads=(\d+) draws=(\d+) '
                            r'capture_calls=0 reconstruction_calls=0', native_log.read_text(errors='replace'))
        if mode == 'direct' and not any(int(draws) >= 300 for _, draws in counts):
            raise ValueError('Direct backend did not activate')
        if mode == 'control' and counts:
            raise ValueError('Control used direct backend')
    finally:
        stop(source)
        try:
            run(wine / 'bin/wineserver', '-k', env=we, timeout=10, stdout=subprocess.DEVNULL)
            run(wine / 'bin/wineserver', '-w', env=we, timeout=10, stdout=subprocess.DEVNULL)
        finally:
            stop(worker)
    return {'mode': mode, 'images': results, 'loaded_sha256': expected}


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('output', 'wine'):
        p.add_argument('--' + name, required=True, type=Path)
    for mode in ('control', 'direct'):
        p.add_argument('--' + mode, type=Path)
    p.add_argument('--compiler', default='x86_64-w64-mingw32-clang++')
    a = p.parse_args()
    if not (a.control or a.direct):
        p.error('Supply --control and/or --direct')
    from PIL import Image  # Check before starting a Wine session.
    out, wine = a.output.resolve(), a.wine.resolve()
    if out.is_relative_to(wine):
        p.error('Output must be separate from input Wine')
    out.mkdir(mode=0o700, parents=True)
    base = {k: v for k, v in os.environ.items()
            if not k.startswith(('BEDROCK_', 'DXMT_', 'WINE', 'DYLD_'))}
    fixture = out / 'direct_d3d.exe'
    run(a.compiler, '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror', '-static',
        HERE / 'fixtures/direct_d3d.cpp', '-ld3d11', '-ldxgi', '-ld3dcompiler', '-luser32',
        '-o', fixture, env=base, timeout=120)
    results = []
    for mode in ('control', 'direct'):
        build = getattr(a, mode)
        if build is not None:
            results.append(case(out / mode, mode, build.resolve(), wine, fixture, base))
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'Passed {sum(len(r["images"]) for r in results)} native GPU readbacks; {out / "results.json"}')


if __name__ == '__main__':
    main()
