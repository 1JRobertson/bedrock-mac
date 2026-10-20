#!/usr/bin/env python3
"""Prepare/build the optional frame-owned slab adapter; never stage or launch it.

The game hook requires an exact executable, explicit opt-in and a fresh control
path. Build the native setting tool with standalone-bedrock-frame-control.py.
The generated DLL remains an isolated experiment until independently validated.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parent
PATCH = ROOT / 'patches/experimental-bedrock-frame-slab.patch'
PATCH_SHA = '4ae728f2528eee3a1be3850135fa6279926f7e22ba6d74cb97f33fa546b0f048'
PROFILE = 'bedrock-frame-slab-1265203-v1'
EXACT_SOURCE_INPUTS_SHA = '6c96c839d418093257d55fd70b28ceec43cc9e58b11514e45198fbbbb3741b37'
PROTOTYPE_DLL_SHA = 'c1f25f252d317274e4aa8ad4d322e5fa9c7ced62e8b4fcf2f08cd305b9157816'
HEADERS = {'frame_adapter.h': '43b98bc5fa7be8e9b5442ca412c606856bd99c3f17b41502a32deac97a282aa9',
 'frame_manifest.h': 'f95e18f48b10033d529c27d5861831addb00f428f3c217204985ffd81e9d1207',
 'frame_slab_core.h': '199d92072413732523e7479db363f732d2b7714dc40caa5facdbf97f1d49dd99'}
PROTOTYPE_INPUTS = {'frame_adapter.h': '9d6c5c9e5f95e2910b0b74b69b8693fd53e6450b140ddf32bdc37f0fb930b34c',
 'frame_manifest.h': 'c26ca48ece63ae2e28c3f4038371ff76c8af8972baf24babde1b17c653db848f',
 'frame_slab_core.h': '2bff26cdd2c6c5a87f8296d47fad6ba0fbee9fdb29aa4cbd783b4bebdd2a7a70'}
EXTRA_HEADERS = {'dlls/ntdll/' + name for name in HEADERS}
SPEC = importlib.util.spec_from_file_location('frame_exact_builder', ROOT / 'standalone-bedrock-allocator.py')
exact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exact)
ref, heap = exact.ref, exact.heap
sha, write, json_bytes = heap.sha, heap.write, heap.json_bytes


def check_patch():
    exact.check_patch()
    if PATCH.is_symlink() or sha(PATCH.read_bytes()) != PATCH_SHA:
        raise RuntimeError('Frame-slab source patch checksum mismatch')


def without_frame_hook(loader):
    for line in (b'#include "frame_adapter.h"\n',
                 b'        bfr_pre_entry( wm->ldr.DllBase, wm->ldr.SizeOfImage );\n',
                 b'    bfr_register_thread();\n'):
        if loader.count(line) != 1:
            raise RuntimeError('Unexpected frame-slab loader integration')
        loader = loader.replace(line, b'', 1)
    return loader


def source_record(source):
    source = ref.canonical_directory(source)
    check_patch()
    if heap.output('git', '-C', source, 'rev-parse', 'HEAD').decode().strip() != ref.COMMIT:
        raise RuntimeError('Unexpected WineGDK source revision')
    tracked = set(heap.output('git', '-C', source, 'diff', '--name-only', 'HEAD', '--', 'dlls/ntdll').decode().splitlines())
    untracked = set(heap.output('git', '-C', source, 'ls-files', '--others', '--exclude-standard', 'dlls/ntdll').decode().splitlines())
    if tracked != {'dlls/ntdll/heap.c', 'dlls/ntdll/loader.c'} or untracked != ref.EXTRA_HEADERS | exact.EXTRA_HEADERS | EXTRA_HEADERS:
        raise RuntimeError('Unexpected ntdll source edits or untracked inputs')
    heap.run('git', '-C', source, 'apply', '--reverse', '--check', PATCH, capture_output=True)
    record = heap.source_record(source)
    baseline = dict(record['source_inputs'])
    for name, digest in HEADERS.items():
        if baseline.pop('dlls/ntdll/' + name, None) != digest:
            raise RuntimeError('Frame-slab header checksum mismatch: ' + name)
    baseline['dlls/ntdll/loader.c'] = sha(without_frame_hook((source / 'dlls/ntdll/loader.c').read_bytes()))
    if sha(json_bytes(baseline)) != EXACT_SOURCE_INPUTS_SHA:
        raise RuntimeError('Base sources differ from the frozen exact-current build')
    record['base_source_inputs_sha256'] = EXACT_SOURCE_INPUTS_SHA
    return record


def manifest(record):
    return dict(record, format=1, profile=PROFILE, architecture='x86_64', wine_version='11.8',
                game_sha256=ref.GAME_SHA, patch_sha256=PATCH_SHA,
                heap_patch_sha256=ref.HEAP_PATCH_SHA, refmove_patch_sha256=ref.PATCH_SHA,
                exact_current_patch_sha256=exact.PATCH_SHA,
                builder_sha256=sha(Path(__file__).read_bytes()), default_enabled=False, stageable=False,
                environment={'BEDROCK_FRAME_SLAB': '1', 'BEDROCK_FRAME_SLAB_CONTROL': 'fresh DOS file path',
                             'BEDROCK_FRAME_SLAB_CHUNK': [0, 4096, 16384, 65536],
                             'required_for_game': {'BEDROCK_PRIVATE_REFMOVE_15203': '1'},
                             'mutually_exclusive': ['BEDROCK_ALLOC_DIAG', 'BEDROCK_EXACT_CURRENT']},
                maximum_reserved_bytes=384 * 1024 * 1024,
                maximum_bytes_per_scope_per_pool=64 * 1024 * 1024,
                maximum_bytes_per_pool=128 * 1024 * 1024,
                control_format={'version': 1, 'size': 65664, 'threads': 512, 'thread_stride': 128},
                prototype_dll_sha256=PROTOTYPE_DLL_SHA, prototype_inputs_sha256=PROTOTYPE_INPUTS,
                integration_changes='Compose frozen slab headers with diagnostic-free exact-current support; add license notices.',
                license='GPL-3.0-or-later adapter; LGPL-2.1-or-later Wine dependency',
                validation='Build only. A new DLL requires isolated correctness and gameplay validation.')


def prepare(args):
    check_patch()
    out = ref.no_symlink_path(args.output)
    original = ref.canonical_directory(args.source)
    if out == original or original in out.parents or out in original.parents:
        raise RuntimeError('Build output and input source must not overlap')
    for name in ('source', 'build', 'toolbin/lld-link', 'configure.log', 'compile.log',
                 'source-inputs.json', 'source-manifest.json', 'ntdll-frame-slab.dll', 'manifest.json'):
        ref.safe_path(out, name)
    source = out / 'source'
    if not source.exists():
        source, _, _ = exact.prepare(args)
        heap.run('git', '-C', source, 'apply', '--check', PATCH, capture_output=True)
        heap.run('git', '-C', source, 'apply', PATCH)
    record = source_record(source)
    inputs = record.pop('source_inputs')
    write(out / 'source-inputs.json', json_bytes(inputs))
    write(out / 'source-manifest.json', json_bytes(manifest(record)))
    return source, out, record


def build(args):
    prefix = ref.canonical_directory(args.wine)
    ref.check_runtime(prefix)  # Read dependencies only; never modify or install into this path.
    header_flags = heap.dependency_header_flags(prefix)
    out = ref.no_symlink_path(args.output)
    if out == prefix or prefix in out.parents or out in prefix.parents:
        raise RuntimeError('Build output and runtime dependencies must not overlap')
    source, out, record = prepare(args)
    build_dir, toolbin = out / 'build', out / 'toolbin'
    build_dir.mkdir(parents=True, exist_ok=True)
    rust = Path(heap.output('rustup', 'run', '1.98.0', 'rustc', '--print', 'sysroot').decode().strip())
    linker = rust / 'lib/rustlib/aarch64-apple-darwin/bin/rust-lld'
    wrapper = '#!/bin/sh\nexport DYLD_LIBRARY_PATH=' + shlex.quote(str(rust / 'lib')) + '\n'
    wrapper += 'exec ' + shlex.quote(str(linker)) + ' -flavor link "$@"\n'
    write(toolbin / 'lld-link', wrapper.encode(), 0o755)
    sdk = heap.output('xcrun', '--show-sdk-path').decode().strip()
    cc = heap.output('xcrun', '--find', 'clang').decode().strip() + ' -arch x86_64 -isysroot ' + shlex.quote(sdk)
    cxx = heap.output('xcrun', '--find', 'clang++').decode().strip() + ' -arch x86_64 -isysroot ' + shlex.quote(sdk)
    env = dict(os.environ, LC_ALL='en_US.UTF-8', CC=cc, CXX=cxx, OBJC=cc,
               CFLAGS='-O2', CXXFLAGS='-O2', OBJCFLAGS='-O2', CROSSCFLAGS='-O2',
               PATH=f'{toolbin}:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/usr/bin:/bin:/opt/homebrew/bin:' + os.environ['PATH'],
               GNUTLS_LIBS=f'-L{prefix}/lib -lgnutls',
               FREETYPE_LIBS=f'-L{prefix}/lib -Wl,-rpath,{prefix}/lib -lfreetype',
               DYLD_FALLBACK_LIBRARY_PATH=f'{prefix}/lib:/usr/lib',
               ac_cv_lib_soname_gnutls='@loader_path/../../libgnutls.30.dylib',
               ac_cv_lib_soname_freetype='@loader_path/../../libfreetype.6.dylib', **header_flags)
    # Avoid producing a host-native allocator: the game and Wine PE ABI are x86-64.
    command = [source / 'configure', '--host=x86_64-apple-darwin24', f'--prefix={prefix}', '--enable-win64',
               '--with-mingw=/opt/homebrew/opt/llvm/bin/clang', '--disable-tests', '--without-x',
               '--with-freetype', '--with-gnutls', '--without-vulkan', '--without-gstreamer', '--without-ffmpeg']
    with (out / 'configure.log').open('wb') as log:
        heap.run(*command, cwd=build_dir, env=env, stdout=log, stderr=subprocess.STDOUT)
    # Headers are injected after upstream configure; force the loader to rebuild.
    ref.safe_path(out, 'build/dlls/ntdll/x86_64-windows/loader.o').unlink(missing_ok=True)
    with (out / 'compile.log').open('wb') as log:
        heap.run('make', f'-j{args.jobs}', 'dlls/ntdll/x86_64-windows/ntdll.dll',
                 cwd=build_dir, env=env, stdout=log, stderr=subprocess.STDOUT)
    data = (build_dir / 'dlls/ntdll/x86_64-windows/ntdll.dll').read_bytes()
    heap.validate_pe(data)
    write(out / 'ntdll-frame-slab.dll', data)
    info = manifest(record)
    info.update(dll_sha256=sha(data), method='isolated-build', configure_command=list(map(str, command)),
                linker_sha256=sha(linker.read_bytes()),
                clang_version=heap.output('/opt/homebrew/opt/llvm/bin/clang', '--version').decode(),
                build_evidence_sha256={name: sha((out / name).read_bytes()) for name in ('configure.log', 'compile.log')})
    write(out / 'manifest.json', json_bytes(info))
    print('Built for isolated validation:', out / 'ntdll-frame-slab.dll')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('prepare', 'build'):
        p = sub.add_parser(command)
        p.add_argument('--source', type=Path, default=ROOT / 'build/standalone-wine/source')
        p.add_argument('--output', type=Path, default=ROOT / 'build/bedrock-frame-slab')
        if command == 'build':
            p.add_argument('--wine', type=Path, default=ROOT / 'runtime/standalone/wine')
            p.add_argument('--jobs', type=int, choices=range(1, 65), default=3)
    args = parser.parse_args()
    if args.command == 'build':
        build(args)
    else:
        source, _, _ = prepare(args)
        print('Prepared opt-in frame-slab source only:', source)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
