#!/usr/bin/env python3
"""Prepare or build the opt-in exact-current allocator; never stage or launch it.

The generated DLL is a new artifact requiring isolated validation. It is not the
frozen prototype DLL, and this helper cannot enable it in a normal installation.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'patches/experimental-bedrock-exact-current.patch'
PATCH_SHA = 'd5d1add946840b8d503558b0c79c997a1c12710b68de54c64c38fbabb083f4ab'
PROFILE = 'bedrock-exact-current-1265203-v2'
PROTOTYPE_DLL_SHA = 'aa2c6c33ae550d8195d06ce6cb9185365143eec3207b411a66ff9d320861acfb'
PROTOTYPE_INPUTS = {
    'exact_adapter.h': '965ff2fa75706435e2421aa23e65b1fe02a782d2d0fd81f8f4e437a3b8349e0d',
    'current_reserve.h': '0b41ce62ac2ea696340768d0f776bba1d2c82073eae053d163d3b5dcc333879d',
    'exact_manifest.h': 'ded1bf83f322a6d7ddb343408a47e5e8905cb60e02989ba50ec6eb195f191524',
    'bedrock_allocator_diag.h': '8d3704a9590cb0225d4aa8def113928a6ec0084a98cba705886fbce79d13f5c8',
}
HEADERS = {
    'exact_adapter.h': '30f5f24fee64a16bd9239e19e599ffcc7768f822bc72e234151d4a7f48941910',
    'current_reserve.h': 'ea2acd0fceaba4fabca73c3ec0da0fd2b84cb919371508b39cd3677d834cf63e',
    'exact_manifest.h': '4a4be49a984c63d3bbdcc9a5c30b21ceddb1210461a8c3e0046759024ddad97a',
    'bedrock_exact_support.h': '7aaf5a81b6b6f34aef84b5e21a80ec480478a3f2d5f93a9b096f421eec3d6d0c',
}
EXTRA_HEADERS = {'dlls/ntdll/' + name for name in HEADERS}
SPEC = importlib.util.spec_from_file_location('allocator_refmove', ROOT / 'experiments/standalone-bedrock-refmove.py')
ref = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ref)
heap = ref.heap
sha, write, json_bytes = heap.sha, heap.write, heap.json_bytes


def check_patch():
    ref.check_patch()
    if PATCH.is_symlink() or sha(PATCH.read_bytes()) != PATCH_SHA:
        raise RuntimeError('Exact-current source patch checksum mismatch')


def without_exact_hook(loader):
    """Recover the pinned refmove loader for source-input provenance verification."""
    for line in (b'#include "bedrock_exact_support.h"\n', b'#include "exact_adapter.h"\n',
                 b'        bad_exact_pre_entry( wm->ldr.DllBase, wm->ldr.SizeOfImage );\n'):
        if loader.count(line) != 1:
            raise RuntimeError('Unexpected exact-current loader integration')
        loader = loader.replace(line, b'', 1)
    return loader


def source_record(source):
    source = ref.canonical_directory(source)
    check_patch()
    if heap.output('git', '-C', source, 'rev-parse', 'HEAD').decode().strip() != ref.COMMIT:
        raise RuntimeError('Unexpected WineGDK source revision')
    tracked = set(heap.output('git', '-C', source, 'diff', '--name-only', 'HEAD', '--', 'dlls/ntdll').decode().splitlines())
    untracked = set(heap.output('git', '-C', source, 'ls-files', '--others', '--exclude-standard', 'dlls/ntdll').decode().splitlines())
    if tracked != {'dlls/ntdll/heap.c', 'dlls/ntdll/loader.c'} or untracked != ref.EXTRA_HEADERS | EXTRA_HEADERS:
        raise RuntimeError('Unexpected ntdll source edits or untracked inputs')
    heap.run('git', '-C', source, 'apply', '--reverse', '--check', PATCH, capture_output=True)
    record = heap.source_record(source)
    baseline = dict(record['source_inputs'])
    for name, digest in HEADERS.items():
        if baseline.pop('dlls/ntdll/' + name, None) != digest:
            raise RuntimeError('Exact-current header checksum mismatch: ' + name)
    baseline['dlls/ntdll/loader.c'] = sha(without_exact_hook((source / 'dlls/ntdll/loader.c').read_bytes()))
    if sha(json_bytes(baseline)) != ref.SOURCE_INPUTS_SHA:
        raise RuntimeError('Base sources differ from the frozen heap/refmove build')
    record['base_source_inputs_sha256'] = ref.SOURCE_INPUTS_SHA
    return record


def manifest(record):
    return dict(record, format=1, profile=PROFILE, architecture='x86_64', wine_version='11.8',
                game_sha256=ref.GAME_SHA, patch_sha256=PATCH_SHA,
                heap_patch_sha256=ref.HEAP_PATCH_SHA, refmove_patch_sha256=ref.PATCH_SHA,
                builder_sha256=sha(Path(__file__).read_bytes()), default_enabled=False, stageable=False,
                environment={'BEDROCK_EXACT_CURRENT': ['off', 'control', 'fast'],
                             'required_for_game': {'BEDROCK_PRIVATE_REFMOVE_15203': '1'}},
                prototype_dll_sha256=PROTOTYPE_DLL_SHA, prototype_inputs_sha256=PROTOTYPE_INPUTS,
                integration_changes='Extract unchanged relay/environment helpers; omit diagnostic hook; correct stale comment; add notices.',
                license='GPL-3.0-or-later adapter; LGPL-2.1-or-later Wine dependency',
                validation='Build only. A new DLL requires isolated correctness and gameplay validation.')


def prepare(args):
    check_patch()
    out = ref.no_symlink_path(args.output)
    original = ref.canonical_directory(args.source)
    if out == original or original in out.parents or out in original.parents:
        raise RuntimeError('Build output and input source must not overlap')
    for name in ('source', 'build', 'toolbin/lld-link', 'configure.log', 'compile.log',
                 'source-inputs.json', 'source-manifest.json', 'ntdll-exact-current.dll', 'manifest.json'):
        ref.safe_path(out, name)
    source = out / 'source'
    if not source.exists():
        patched = sha((original / 'dlls/ntdll/heap.c').read_bytes()) == ref.HEAP_SHA
        # Input must be the pinned standalone source, with at most the heap fix.
        heap.validate_source(original, patched)
        out.mkdir(parents=True, exist_ok=True)
        heap.run('/bin/cp', '-cRp', original, source)
        if not patched:
            heap.run('git', '-C', source, 'apply', heap.PATCH)
        heap.run('git', '-C', source, 'apply', ref.PATCH)
        ref.source_record(source)
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
    with (out / 'compile.log').open('wb') as log:
        heap.run('make', f'-j{args.jobs}', 'dlls/ntdll/x86_64-windows/ntdll.dll',
                 cwd=build_dir, env=env, stdout=log, stderr=subprocess.STDOUT)
    data = (build_dir / 'dlls/ntdll/x86_64-windows/ntdll.dll').read_bytes()
    heap.validate_pe(data)
    write(out / 'ntdll-exact-current.dll', data)
    info = manifest(record)
    info.update(dll_sha256=sha(data), method='isolated-build', configure_command=list(map(str, command)),
                linker_sha256=sha(linker.read_bytes()),
                clang_version=heap.output('/opt/homebrew/opt/llvm/bin/clang', '--version').decode(),
                build_evidence_sha256={name: sha((out / name).read_bytes()) for name in ('configure.log', 'compile.log')})
    write(out / 'manifest.json', json_bytes(info))
    print('Built for isolated validation:', out / 'ntdll-exact-current.dll')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('prepare', 'build'):
        p = sub.add_parser(command)
        p.add_argument('--source', type=Path, default=ROOT / 'build/standalone-wine/source')
        p.add_argument('--output', type=Path, default=ROOT / 'build/bedrock-exact-current')
        if command == 'build':
            p.add_argument('--wine', type=Path, default=ROOT / 'runtime/standalone/wine')
            p.add_argument('--jobs', type=int, choices=range(1, 65), default=3)
    args = parser.parse_args()
    if args.command == 'build':
        build(args)
    else:
        source, _, _ = prepare(args)
        print('Prepared opt-in source only:', source)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
