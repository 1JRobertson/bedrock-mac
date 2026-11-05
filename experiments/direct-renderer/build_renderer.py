#!/usr/bin/env python3
"""Build one isolated research renderer from this checkout and pinned DXMT."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
DXMT = json.loads((HERE / 'dxmt-source.json').read_text())
PE = ('d3d11', 'winemetal')
UPSTREAM_BRIDGE_SHA = '3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca'
UPSTREAM_DXGI_SHA = 'fc58aae0aba511a1ec4d2417e5bba6adb888bb14315d0f59cccdfd27f670d544'
ARC = 'shared_texture shared_texture_attachment shared_texture_pass_capture metadata_wire_encode'.split()
MANUAL = ('snapshot shader_client shader_ia command_capture draw_capture draw_replay_capture '
          'resource_capture draw_resource_cut draw_cut_bridge frame_stream_payload chunk_stream_producer').split()
C = ('trace shader_pair shader_handles resource_transport frame_stream frame_stream_capture '
     'chunk_stream chunk_completion readback_stream shared_snapshot_arena native_boundary_upload retained_observer').split()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def prepare(out, upstream, mode):
    if subprocess.check_output(['git', '-C', upstream, 'rev-parse', 'HEAD'],
                               text=True).strip() != DXMT['revision']:
        raise ValueError('DXMT checkout is not at the pinned revision')
    if subprocess.check_output(['git', '-C', upstream, 'status', '--porcelain',
                                '--untracked-files=no'], text=True):
        raise ValueError('DXMT checkout must have clean tracked files and submodules')
    out.mkdir(mode=0o700, parents=True)
    dxmt = out / 'dxmt'
    shutil.copytree(upstream, dxmt, ignore=shutil.ignore_patterns('.git'), symlinks=True)
    for name in ('source', 'native-source'):
        shutil.copytree(HERE / name, out / name)
    run('git', 'apply', HERE / 'dxmt-direct-renderer.patch', cwd=dxmt)
    for item in DXMT['changed']:
        if sha(dxmt / item['path']) != item['candidate_sha256']:
            raise ValueError('Unexpected DXMT bytes: ' + item['path'])
    if mode == 'control':
        run('git', 'apply', HERE / 'faster-control.patch', cwd=out)
        for path, digest in json.loads((HERE / 'faster-control.json').read_text()).items():
            if sha(out / path) != digest:
                raise ValueError('Unexpected control bytes: ' + path)


def bridge(out, wine):
    unix = wine / 'lib/wine/x86_64-unix'
    library = out / 'winemetal.so'
    upstream = out / 'winemetal-upstream.so'
    for name in ('winemetal-upstream.so', 'winemetal.so'):
        candidate = unix / name
        if candidate.is_file() and sha(candidate) == UPSTREAM_BRIDGE_SHA:
            shutil.copyfile(candidate, upstream)
            break
    else:
        raise ValueError('Wine needs the original DXMT 0.80 winemetal bridge')
    if sha(wine / 'lib/wine/x86_64-windows/dxgi.dll') != UPSTREAM_DXGI_SHA:
        raise ValueError('Wine needs the original DXMT 0.80 DXGI module')
    source = out / 'source'
    platform = ['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=15.0']
    flags = ['-O2', '-Wall', '-Wextra', '-Werror', '-fblocks',
             '-DBEDROCK_NATIVE_DRAW_CUT', '-DBEDROCK_NATIVE_FRAME_STREAM',
             '-DBEDROCK_BOUNDARY_UPLOADS', '-I', source, '-I', out / 'native-source',
             '-I', HERE / 'bridge', '-I', out / 'dxmt/src/airconv']
    bridge_obj = out / 'bridge.o'
    run(*platform, *flags, '-Wno-unused-parameter', '-std=gnu2x', '-fno-objc-arc', '-x', 'objective-c', '-c',
        HERE / 'bridge/unix/winemetal_unix.c', '-o', bridge_obj)
    objects = [bridge_obj]
    for group in (ARC, MANUAL, C):
        for name in group:
            obj = out / (name + '.o')
            args = (['-std=gnu11'] if group is C else ['-std=gnu2x'] +
                    (['-fobjc-arc', '-fobjc-arc-exceptions'] if group is ARC else ['-fno-objc-arc']))
            run(*platform, *flags, *args, '-c',
                source / (name + ('.c' if group is C else '.m')), '-o', obj)
            objects.append(obj)
    frameworks = [v for f in ('Cocoa', 'Metal', 'MetalFX', 'ColorSync', 'QuartzCore',
                               'CoreFoundation') for v in ('-framework', f)]
    optional = ['-Wl,-U,_fullframe_boundary_' + f for f in
                ('inprocess', 'native_bind', 'native_tables', 'trace_encoder')]
    run(*platform, '-dynamiclib', *objects, upstream, unix / 'ntdll.so',
        unix / 'winemac.so', *frameworks, *optional,
        '-Wl,-install_name,@rpath/winemetal-research.so', '-Wl,-rpath,@loader_path', '-o', library)
    run('/usr/bin/install_name_tool', '-change', '@rpath/winemetal.so',
        '@loader_path/winemetal-upstream.so', '-id', '@rpath/winemetal.so', library)
    run('/usr/bin/codesign', '--force', '--sign', '-', library)


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=('direct', 'control'))
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--dxmt', required=True, type=Path)
    p.add_argument('--wine', required=True, type=Path)
    p.add_argument('--meson', default='meson')
    p.add_argument('--bridge-only', action='store_true')
    a = p.parse_args()
    out, dxmt, wine = (v.resolve() for v in (a.output, a.dxmt, a.wine))
    prepare(out, dxmt, a.mode)
    bridge(out, wine)
    if a.bridge_only:
        return
    # Build only the two modified PE modules. DXGI and D3D10Core are supplied by
    # the existing compatible Wine/DXMT runtime.
    defines = '-DBEDROCK_NATIVE_DRAW_CUT -DBEDROCK_NATIVE_FRAME_STREAM -DBEDROCK_NATIVE_ENTRY'
    run(a.meson, 'setup', out / 'pe', out / 'dxmt', '--cross-file',
        out / 'dxmt/build-win64.txt', '--buildtype', 'release',
        '-Dwine_install_path=' + str(wine), '-Dc_args=' + defines, '-Dcpp_args=' + defines)
    run('ninja', '-C', out / 'pe', '-j', '2',
        *[f'src/{name}/{name}.dll' for name in PE])
    for name in PE:
        dll = out / (name + '.dll')
        shutil.copyfile(out / 'pe' / 'src' / name / dll.name, dll)
        run(wine / 'bin/winebuild', '--builtin', dll)
    from build_native import build
    build(out / 'native-source', out / 'worker')
    files = ('winemetal.so', 'winemetal-upstream.so', 'd3d11.dll', 'winemetal.dll',
             'worker/native-draw-executor')
    (out / 'renderer.json').write_text(json.dumps({'mode': a.mode, 'files': {
        name: sha(out / name) for name in files}}, indent=2) + '\n')


if __name__ == '__main__':
    main()
