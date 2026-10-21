#!/usr/bin/env python3
"""Package and reversibly stage an exact-build, default-off Bedrock experiment.

This never edits Minecraft.Windows.exe or launcher configuration. A staged marker
only requests a gate; a launcher must separately validate its phase and DLL hash.
Fresh builds are saved for review, not silently substituted for the tested DLL.
"""
import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/bedrock-refmove'
PATCH = ROOT / 'patches/experimental-bedrock-refmove.patch'
PATCH_SHA = '9d7755a1edf27511e791367c17bcb188ac64fa939b9ec021342979511a0e6430'
HEAP_PATCH_SHA = '0999590811dad880eb1a9153443ada7f90c65dfb8e9db4974b1a9a4364b17890'
SOURCE_INPUTS_SHA = '4c277f20ef61340891317f7483553a5924e6d2049a99ae6103519b8c5e2dc0b2'
TESTED_DLL_SHA = '3a5e665897b7e73d09f1e9062e88214c6f391da61ec625a0cd14efc124a2eb6c'
BASE_DLL_SHA = '1cfaab9891fcaa0668d94a819e8840d0b911b7f9216dc52f51b352520b18f06f'
GAME_SHA = '4a92bfa3ce2428b40ee517b7c1125d9f6f79274382de03846351992663b2e2e4'
ENVIRONMENT = 'BEDROCK_PRIVATE_REFMOVE_15203'
STATUS = 'bedrock-refmove.json'
BACKUPS = 'bedrock-refmove-backups'
PROFILE = 'private-bedrock-refmove-1265203-v1'
MANIFEST = 'build-manifest.json'
SPEC = importlib.util.spec_from_file_location('refmove_heap_support', ROOT / 'experiments/standalone-wine-heap.py')
heap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(heap)
COMMIT, HEAP_SHA, DLL, UNIX = heap.COMMIT, heap.HEAP_SHA, heap.DLL, heap.UNIX
sha, json_bytes, write, validate_pe = heap.sha, heap.json_bytes, heap.write, heap.validate_pe
EXTRA_HEADERS = {'dlls/ntdll/' + n for n in (
    'bedrock_private_refmove.h', 'bedrock_private_refmove_sentinel.h', 'guarded_refmove.h', 'manifest.h')}


def no_symlink_path(path):
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        if part.is_symlink():
            raise RuntimeError('Refusing symlink path: ' + str(part))
    return path


def canonical_directory(path):
    path = no_symlink_path(path)
    if not path.is_dir():
        raise RuntimeError('Missing directory: ' + str(path))
    return path


def safe_path(root, relative):
    relative = Path(relative)
    if relative.is_absolute() or '..' in relative.parts:
        raise RuntimeError('Refusing escaping runtime path')
    path = root
    for part in relative.parts:
        path /= part
        if path.is_symlink():
            raise RuntimeError('Refusing symlink runtime path: ' + str(path))
    return path


def check_patch():
    if PATCH.is_symlink() or sha(PATCH.read_bytes()) != PATCH_SHA:
        raise RuntimeError('Experimental source patch checksum mismatch')
    if heap.PATCH.is_symlink() or sha(heap.PATCH.read_bytes()) != HEAP_PATCH_SHA:
        raise RuntimeError('Required heap source patch checksum mismatch')


def source_record(source):
    source = canonical_directory(source)
    check_patch()
    if heap.output('git', '-C', source, 'rev-parse', 'HEAD').decode().strip() != COMMIT:
        raise RuntimeError('Unexpected WineGDK source revision')
    tracked = set(heap.output('git', '-C', source, 'diff', '--name-only', 'HEAD', '--', 'dlls/ntdll').decode().splitlines())
    untracked = set(heap.output('git', '-C', source, 'ls-files', '--others', '--exclude-standard', 'dlls/ntdll').decode().splitlines())
    if tracked != {'dlls/ntdll/heap.c', 'dlls/ntdll/loader.c'} or untracked != EXTRA_HEADERS:
        raise RuntimeError('Unexpected ntdll source edits or untracked inputs')
    heap.run('git', '-C', source, 'apply', '--reverse', '--check', PATCH, capture_output=True)
    heap.run('git', '-C', source, 'apply', '--reverse', '--check', heap.PATCH, capture_output=True)
    record = heap.source_record(source)
    if record['source_inputs_sha256'] != SOURCE_INPUTS_SHA:
        raise RuntimeError('Source inputs differ from the frozen reviewed build')
    if sha((source / 'dlls/ntdll/heap.c').read_bytes()) != HEAP_SHA:
        raise RuntimeError('Required 48-byte heap fix differs')
    return record


def package(source, dll, method, evidence):
    record = source_record(source)
    validate_pe(dll)
    if sha(dll) != TESTED_DLL_SHA:
        raise RuntimeError('Only the exact tested DLL can be packaged for staging')
    inputs = record.pop('source_inputs')
    artifact = dict(record, format=1, profile=PROFILE, method=method,
                    architecture='x86_64', wine_version='11.8', dll_sha256=TESTED_DLL_SHA,
                    patch_sha256=PATCH_SHA, heap_patch_sha256=HEAP_PATCH_SHA,
                    game_sha256=GAME_SHA, environment=ENVIRONMENT, default_enabled=False,
                    builder_sha256=sha(Path(__file__).read_bytes()), build_evidence_sha256=evidence,
                    license='LGPL-2.1-or-later',
                    validation='Frozen private experiment; no performance claim. Runtime gate defaults off.')
    no_symlink_path(OUT)
    OUT.mkdir(parents=True, exist_ok=True)
    canonical_directory(OUT)
    for name in ('ntdll.dll', 'manifest.json', 'source-inputs.json'):
        safe_path(OUT, name)
    write(OUT / 'source-inputs.json', json_bytes(inputs))
    write(OUT / 'ntdll.dll', dll)
    write(OUT / 'manifest.json', json_bytes(artifact))
    print('Prepared exact tested artifact:', OUT / 'ntdll.dll')


def import_from_build(args):
    source_root = canonical_directory(args.build_dir)
    names = ('ntdll-private-refmove.dll', 'build.py', 'build-result.json', 'configure.log', 'compile.log')
    files = {n: safe_path(source_root, n) for n in names}
    dll = files['ntdll-private-refmove.dll'].read_bytes()
    if sha(dll) != TESTED_DLL_SHA:
        raise RuntimeError('Import requires the frozen tested candidate')
    result = json.loads(files['build-result.json'].read_bytes())
    if result.get('dll_sha256') != TESTED_DLL_SHA or result.get('heap_source_sha256') != HEAP_SHA:
        raise RuntimeError('Build evidence does not identify the reviewed DLL and heap fix')
    package(source_root / 'wine-source', dll, 'import-tested-build',
            {name: sha(path.read_bytes()) for name, path in files.items() if name != 'ntdll-private-refmove.dll'})


def artifact_identity():
    return {'format': 1, 'profile': PROFILE, 'source_commit': COMMIT,
                'heap_source_sha256': HEAP_SHA, 'source_inputs_sha256': SOURCE_INPUTS_SHA,
                'dll_sha256': TESTED_DLL_SHA, 'patch_sha256': PATCH_SHA,
                'heap_patch_sha256': HEAP_PATCH_SHA, 'game_sha256': GAME_SHA,
                'architecture': 'x86_64', 'wine_version': '11.8', 'environment': ENVIRONMENT,
                'default_enabled': False}


def verified_artifact():
    canonical_directory(OUT)
    check_patch()
    dll = safe_path(OUT, 'ntdll.dll').read_bytes()
    artifact = json.loads(safe_path(OUT, 'manifest.json').read_bytes())
    inputs_data = safe_path(OUT, 'source-inputs.json').read_bytes()
    inputs = json.loads(inputs_data)
    if (sha(dll) != TESTED_DLL_SHA or sha(json_bytes(inputs)) != SOURCE_INPUTS_SHA or
            any(artifact.get(key) != value for key, value in artifact_identity().items()) or
            artifact.get('default_enabled') is not False or
            inputs.get('dlls/ntdll/heap.c') != HEAP_SHA):
        raise RuntimeError('Artifact byte/hash/source verification failed')
    validate_pe(dll)
    return dll, artifact


def check_runtime(runtime):
    metadata = json.loads(safe_path(runtime, MANIFEST).read_bytes())
    if (metadata.get('wine_source_revision') != COMMIT or metadata.get('architecture') != 'x86_64' or
            metadata.get('wine_version') not in ('11.8', 'wine-11.8')):
        raise RuntimeError('Requires the pinned x86_64 WineGDK 11.8 runtime')
    for name in (DLL, UNIX):
        if not safe_path(runtime, name).is_file():
            raise RuntimeError('Missing runtime module: ' + str(name))
    return metadata


def baseline_profile(runtime, metadata):
    marker = safe_path(runtime, heap.STATUS).read_bytes()
    info = json.loads(marker)
    declared = metadata.get('local_modifications', {}).get('heap_reuse', {})
    for entry in (info, declared):
        if (entry.get('dll_sha256') != BASE_DLL_SHA or entry.get('source_commit') != COMMIT or
                entry.get('heap_source_sha256') != HEAP_SHA):
            raise RuntimeError('Overlapping or mismatched heap profile; restore it before staging')
    return marker


def refuse_active(runtime):
    names = [safe_path(runtime, DLL), safe_path(runtime, UNIX)]
    result = subprocess.run(['/usr/sbin/lsof', '-Fpn', '--', *map(str, names)], text=True, capture_output=True)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError('Could not establish whether this Wine runtime is idle')
    if any(line.startswith('p') for line in result.stdout.splitlines()):
        raise RuntimeError('Close applications using this Wine runtime first')


@contextmanager
def runtime_lock(runtime):
    # Share the heap helper's lock because both replace the same Windows ntdll.
    paths = [safe_path(runtime, n) for n in ('.wine-heap-reuse.lock', '.bedrock-refmove.lock')]
    owned = []
    try:
        for path in paths:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            owned.append((path, fd))
            os.write(fd, str(os.getpid()).encode())
        yield
    finally:
        for path, fd in reversed(owned):
            os.close(fd)
            path.unlink()


def verified_backups(runtime, record):
    if (record.get('format') != 1 or record.get('profile') != PROFILE or
            record.get('dll_sha256') != TESTED_DLL_SHA or record.get('previous_sha256') != BASE_DLL_SHA or
            record.get('phase') not in ('prepared', 'staged') or
            record.get('environment') != ENVIRONMENT or record.get('game_sha256') != GAME_SHA or
            type(record.get('requested_gate')) is not bool or record.get('previous_marker_present') is not False):
        raise RuntimeError('Unrecognized or mismatched staging marker')
    original = safe_path(runtime, record['backup']).read_bytes()
    old_manifest = safe_path(runtime, record['manifest_backup']).read_bytes()
    if sha(original) != BASE_DLL_SHA or sha(old_manifest) != record['previous_manifest_sha256']:
        raise RuntimeError('Backup checksum mismatch')
    for key in ('previous_mode', 'previous_manifest_mode'):
        if type(record.get(key)) is not int or not 0 <= record[key] <= 0o7777:
            raise RuntimeError('Invalid backup mode in staging marker')
    return original, old_manifest


def verified_activation(runtime, game=None):
    """Return the verified requested gate, or False when no marker is present.

    Read-only: no lsof, environment changes, or build-artifact dependency. Any
    invalid/partial staged state raises RuntimeError, even when its gate is off.
    Passing a game directory additionally hashes its Minecraft.Windows.exe in
    bounded chunks; omit it when the caller only needs staged-state verification.
    A launcher must clear inherited gate values unless this returns True.
    """
    try:
        runtime = canonical_directory(runtime)
        status = safe_path(runtime, STATUS)
        if not status.exists():
            return False
        locks = [safe_path(runtime, name) for name in ('.wine-heap-reuse.lock', '.bedrock-refmove.lock')]
        if any(path.exists() for path in locks):
            raise RuntimeError('Runtime profile update in progress; activation refused')
        status_data = status.read_bytes()
        record = json.loads(status_data)
        verified_backups(runtime, record)
        if record['phase'] != 'staged':
            raise RuntimeError('Partial refmove profile; activation refused')
        metadata_path = safe_path(runtime, MANIFEST)
        metadata_data = metadata_path.read_bytes()
        metadata = check_runtime(runtime)
        declared = metadata.get('local_modifications', {}).get('bedrock_refmove', {})
        if (any(declared.get(key) != value for key, value in artifact_identity().items()) or
                declared.get('default_enabled') is not False or
                declared.get('requested_gate') is not record['requested_gate']):
            raise RuntimeError('Staged refmove source or gate identity mismatch')
        if sha(metadata_data) != record['staged_manifest_sha256']:
            raise RuntimeError('Staged runtime manifest checksum mismatch')
        heap_marker = baseline_profile(runtime, metadata)
        if sha(heap_marker) != record['heap_marker_sha256']:
            raise RuntimeError('Staged heap marker checksum mismatch')
        for entry in (json.loads(heap_marker), metadata['local_modifications']['heap_reuse']):
            if entry.get('patch_sha256') != HEAP_PATCH_SHA:
                raise RuntimeError('Staged heap source patch identity mismatch')
        if sha(safe_path(runtime, DLL).read_bytes()) != TESTED_DLL_SHA:
            raise RuntimeError('Staged refmove DLL checksum mismatch')
        if game is not None:
            game = safe_path(canonical_directory(game), 'Minecraft.Windows.exe')
            digest = hashlib.sha256()
            with game.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            if digest.hexdigest() != GAME_SHA:
                raise RuntimeError('Unsupported Minecraft executable checksum')
        if (status.read_bytes() != status_data or metadata_path.read_bytes() != metadata_data or
                safe_path(runtime, heap.STATUS).read_bytes() != heap_marker or any(path.exists() for path in locks)):
            raise RuntimeError('Runtime profile changed during activation verification')
        return record['requested_gate']
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise RuntimeError('Cannot verify refmove activation: ' + str(error)) from error


def restore_locked(runtime, record, status):
    original, old_manifest = verified_backups(runtime, record)
    target, metadata = safe_path(runtime, DLL), safe_path(runtime, MANIFEST)
    if sha(target.read_bytes()) not in (TESTED_DLL_SHA, BASE_DLL_SHA):
        raise RuntimeError('DLL changed since staging; refusing to overwrite')
    if sha(metadata.read_bytes()) not in (record['staged_manifest_sha256'], record['previous_manifest_sha256']):
        raise RuntimeError('Runtime manifest changed since staging; refusing to overwrite')
    if sha(safe_path(runtime, heap.STATUS).read_bytes()) != record['heap_marker_sha256']:
        raise RuntimeError('Heap profile marker changed since staging')
    write(target, original, record['previous_mode'])
    write(metadata, old_manifest, record['previous_manifest_mode'])
    if target.read_bytes() != original or metadata.read_bytes() != old_manifest:
        raise RuntimeError('Restore verification failed; recovery marker retained')
    # There was no refmove marker before this stage; remove only after full restore.
    status.unlink()
    print('Restored the exact previous ntdll and runtime manifest; removed the experiment marker.')


def stage(args, restore=False):
    runtime = canonical_directory(args.wine)
    with runtime_lock(runtime):
        check_runtime(runtime)
        refuse_active(runtime)
        target, metadata = safe_path(runtime, DLL), safe_path(runtime, MANIFEST)
        status = safe_path(runtime, STATUS)
        if restore:
            restore_locked(runtime, json.loads(status.read_bytes()), status)
            return
        dll, artifact = verified_artifact()
        requested = bool(args.enable)
        if status.exists():
            record = json.loads(status.read_bytes())
            verified_backups(runtime, record)
            if (record.get('profile') == PROFILE and record.get('phase') == 'staged' and
                    record.get('dll_sha256') == TESTED_DLL_SHA and record.get('requested_gate') is requested and
                    sha(target.read_bytes()) == TESTED_DLL_SHA and
                    sha(metadata.read_bytes()) == record.get('staged_manifest_sha256') and
                    sha(safe_path(runtime, heap.STATUS).read_bytes()) == record.get('heap_marker_sha256')):
                print('Already staged with the requested gate.')
                return
            raise RuntimeError('Existing or partial profile differs; restore it before staging again')
        previous, old_manifest = target.read_bytes(), metadata.read_bytes()
        if sha(previous) != BASE_DLL_SHA:
            raise RuntimeError('Requires the exact reviewed 48-byte heap DLL; refusing overlapping profile')
        validate_pe(previous)
        previous_metadata = json.loads(old_manifest)
        if 'bedrock_refmove' in previous_metadata.get('local_modifications', {}):
            raise RuntimeError('Untracked overlapping refmove profile in runtime manifest')
        heap_marker = baseline_profile(runtime, previous_metadata)
        backup_dir = Path(BACKUPS) / BASE_DLL_SHA
        record = dict(format=1, profile=PROFILE, phase='prepared', dll_sha256=TESTED_DLL_SHA,
                      environment=ENVIRONMENT, game_sha256=GAME_SHA, requested_gate=requested,
                      previous_sha256=BASE_DLL_SHA, previous_manifest_sha256=sha(old_manifest),
                      previous_mode=stat.S_IMODE(target.stat().st_mode),
                      previous_manifest_mode=stat.S_IMODE(metadata.stat().st_mode),
                      heap_marker_sha256=sha(heap_marker), previous_marker_present=False,
                      backup=str(backup_dir / 'ntdll.dll'),
                      manifest_backup=str(backup_dir / ('build-manifest.' + sha(old_manifest) + '.json')))
        staged = json.loads(old_manifest)
        staged.setdefault('local_modifications', {})['bedrock_refmove'] = dict(artifact, requested_gate=requested)
        staged_manifest = json_bytes(staged)
        record['staged_manifest_sha256'] = sha(staged_manifest)
        for key, content in (('backup', previous), ('manifest_backup', old_manifest)):
            backup = safe_path(runtime, record[key])
            if backup.exists() and backup.read_bytes() != content:
                raise RuntimeError('Existing backup is corrupt')
            if not backup.exists():
                write(backup, content)
        # Journal precedes either mutable runtime file; restore accepts every partial state.
        write(status, json_bytes(record))
        write(target, dll, record['previous_mode'])
        write(metadata, staged_manifest, record['previous_manifest_mode'])
        if target.read_bytes() != dll or metadata.read_bytes() != staged_manifest:
            raise RuntimeError('Stage verification failed; restore using the retained marker')
        record['phase'] = 'staged'
        write(status, json_bytes(record))
        print('Staged private experiment; requested gate:', 'on' if requested else 'off')
        print('Launcher integration is separate; the game executable was not modified.')


def build(args):
    """Reproduce reviewed sources; save new bytes separately for validation."""
    check_patch()
    prefix = canonical_directory(args.wine)
    check_runtime(prefix)
    no_symlink_path(OUT)
    for relative in ('source', 'build', 'toolbin/lld-link', 'configure.log', 'compile.log',
                     'rebuilt-ntdll.dll', 'rebuilt-source-inputs.json', 'rebuilt-manifest.json'):
        safe_path(OUT, relative)
    source, build_dir, toolbin = OUT / 'source', OUT / 'build', OUT / 'toolbin'
    if not source.exists():
        original = canonical_directory(args.source)
        patched = sha((original / 'dlls/ntdll/heap.c').read_bytes()) == HEAP_SHA
        heap.validate_source(original, patched)
        OUT.mkdir(parents=True, exist_ok=True)
        heap.run('/bin/cp', '-cRp', original, source)
        if not patched:
            heap.run('git', '-C', source, 'apply', heap.PATCH)
        heap.run('git', '-C', source, 'apply', PATCH)
    record = source_record(source)
    build_dir.mkdir(parents=True, exist_ok=True)
    rust = Path(heap.output('rustup', 'run', '1.98.0', 'rustc', '--print', 'sysroot').decode().strip())
    linker = rust / 'lib/rustlib/aarch64-apple-darwin/bin/rust-lld'
    write(toolbin / 'lld-link', ('#!/bin/sh\nexport DYLD_LIBRARY_PATH=' + shlex.quote(str(rust / 'lib')) +
                                '\nexec ' + shlex.quote(str(linker)) + ' -flavor link "$@"\n').encode(), 0o755)
    sdk = heap.output('xcrun', '--show-sdk-path').decode().strip()
    cc = heap.output('xcrun', '--find', 'clang').decode().strip() + ' -arch x86_64 -isysroot ' + shlex.quote(sdk)
    cxx = heap.output('xcrun', '--find', 'clang++').decode().strip() + ' -arch x86_64 -isysroot ' + shlex.quote(sdk)
    env = dict(os.environ, LC_ALL='en_US.UTF-8', CC=cc, CXX=cxx, OBJC=cc,
               CFLAGS='-O2', CXXFLAGS='-O2', OBJCFLAGS='-O2', CROSSCFLAGS='-O2',
               PATH=f'{toolbin}:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/usr/bin:/bin:/opt/homebrew/bin:' + os.environ['PATH'],
               GNUTLS_CFLAGS='-I/opt/homebrew/opt/gnutls/include', GNUTLS_LIBS=f'-L{prefix}/lib -lgnutls',
               FREETYPE_CFLAGS='-I/opt/homebrew/opt/freetype/include/freetype2',
               FREETYPE_LIBS=f'-L{prefix}/lib -Wl,-rpath,{prefix}/lib -lfreetype',
               DYLD_FALLBACK_LIBRARY_PATH=f'{prefix}/lib:/usr/lib',
               ac_cv_lib_soname_gnutls='@loader_path/../../libgnutls.30.dylib',
               ac_cv_lib_soname_freetype='@loader_path/../../libfreetype.6.dylib')
    command = [source / 'configure', '--host=x86_64-apple-darwin24', f'--prefix={prefix}', '--enable-win64',
               '--with-mingw=/opt/homebrew/opt/llvm/bin/clang', '--disable-tests', '--without-x',
               '--with-freetype', '--with-gnutls', '--without-vulkan', '--without-gstreamer', '--without-ffmpeg']
    with (OUT / 'configure.log').open('wb') as log:
        heap.run(*command, cwd=build_dir, env=env, stdout=log, stderr=subprocess.STDOUT)
    with (OUT / 'compile.log').open('wb') as log:
        heap.run('make', f'-j{args.jobs}', 'dlls/ntdll/x86_64-windows/ntdll.dll',
                 cwd=build_dir, env=env, stdout=log, stderr=subprocess.STDOUT)
    dll = build_dir / 'dlls/ntdll/x86_64-windows/ntdll.dll'
    data = dll.read_bytes()
    validate_pe(data)
    write(OUT / 'rebuilt-ntdll.dll', data)
    inputs = record.pop('source_inputs')
    write(OUT / 'rebuilt-source-inputs.json', json_bytes(inputs))
    write(OUT / 'rebuilt-manifest.json', json_bytes(dict(record, dll_sha256=sha(data), patch_sha256=PATCH_SHA,
        heap_patch_sha256=HEAP_PATCH_SHA, method='isolated-build-needs-validation',
        configure_command=list(map(str, command)), linker_sha256=sha(linker.read_bytes()),
        builder_sha256=sha(Path(__file__).read_bytes()), default_enabled=False,
        stageable=sha(data) == TESTED_DLL_SHA)))
    print('Built for review:', OUT / 'rebuilt-ntdll.dll')
    print('Staging continues to accept only the exact frozen tested artifact.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('import-from-build')
    p.add_argument('--build-dir', type=Path, default=ROOT / 'build/performance/worker-attribution/refmove-prototype')
    p = sub.add_parser('build')
    p.add_argument('--source', type=Path, default=ROOT / 'build/standalone-wine/source')
    p.add_argument('--wine', type=Path, default=ROOT / 'runtime/standalone/wine')
    p.add_argument('--jobs', type=int, choices=range(1, 65), default=3)
    for name in ('stage', 'restore'):
        p = sub.add_parser(name)
        p.add_argument('--wine', type=Path, required=True)
        if name == 'stage':
            p.add_argument('--enable', action='store_true', help='Record an explicit gate request; launcher support remains separate.')
    args = parser.parse_args()
    if args.command == 'import-from-build': import_from_build(args)
    elif args.command == 'build': build(args)
    else: stage(args, args.command == 'restore')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
