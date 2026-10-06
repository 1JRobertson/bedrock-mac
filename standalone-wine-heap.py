#!/usr/bin/env python3
"""Explicitly build, import, stage, or restore the experimental Wine heap cache."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'build/wine-heap-reuse'
PATCH = ROOT / 'patches/experimental-wine-heap-reuse.patch'
COMMIT = 'b5d23b074cfd5e28e79acceaaefaf41a26ce6272'
BASE_HEAP_SHA = '445b7839255cb68d63dbe979847633c3df76d27a0afb2ab233d1d20f985bdcbd'
HEAP_SHA = '986c49e31952df27a26d7b5128b5fb588b070ff0e017206693414ff944a8a14e'
TESTED_DLL_SHA = '1cfaab9891fcaa0668d94a819e8840d0b911b7f9216dc52f51b352520b18f06f'
PROVENANCE = 'https://github.com/Roritharr/bedrock-on-macos/blob/main/docs/performance.md'
DLL = Path('lib/wine/x86_64-windows/ntdll.dll')
UNIX = Path('lib/wine/x86_64-unix/ntdll.so')
STATUS = 'wine-heap-reuse.json'
BACKUPS = 'wine-heap-reuse-backups'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def output(*args):
    return subprocess.check_output([str(x) for x in args])


def json_bytes(data):
    return (json.dumps(data, indent=2, sort_keys=True) + '\n').encode()


def write(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def validate_pe(data):
    if len(data) < 128 or data[:2] != b'MZ' or b'Wine builtin DLL' not in data[:128]:
        raise RuntimeError('Expected a Wine builtin PE DLL')
    offset = struct.unpack_from('<I', data, 60)[0]
    if offset + 26 > len(data) or data[offset:offset + 4] != b'PE\0\0':
        raise RuntimeError('Invalid PE header')
    if struct.unpack_from('<H', data, offset + 4)[0] != 0x8664:
        raise RuntimeError('Expected x86_64 ntdll.dll')
    if struct.unpack_from('<H', data, offset + 24)[0] != 0x20b:
        raise RuntimeError('Expected PE32+ ntdll.dll')


def validate_source(source, patched):
    if output('git', '-C', source, 'rev-parse', 'HEAD').decode().strip() != COMMIT:
        raise RuntimeError('Unexpected WineGDK source revision')
    names = output('git', '-C', source, 'diff', '--name-only', 'HEAD', '--', 'dlls/ntdll').decode().splitlines()
    expected = ['dlls/ntdll/heap.c'] if patched else []
    if names != expected or output('git', '-C', source, 'ls-files', '--others', '--exclude-standard', 'dlls/ntdll'):
        raise RuntimeError('Unexpected ntdll source edits or untracked inputs')
    expected_sha = HEAP_SHA if patched else BASE_HEAP_SHA
    if sha((source / 'dlls/ntdll/heap.c').read_bytes()) != expected_sha:
        raise RuntimeError('Heap implementation differs from the reviewed candidate')
    if patched:
        run('git', '-C', source, 'apply', '--reverse', '--check', PATCH, capture_output=True)


def source_record(source):
    # Include headers and static-library/build-tool inputs, including local standalone patches.
    inputs = {}
    for directory in ('dlls/ntdll', 'include', 'libs', 'tools'):
        for path in sorted((source / directory).rglob('*')):
            if path.is_file():
                inputs[str(path.relative_to(source))] = sha(path.read_bytes())
    inputs['configure'] = sha((source / 'configure').read_bytes())
    return {'source_commit': COMMIT, 'heap_source_sha256': HEAP_SHA,
            'upstream_heap_source_sha256': BASE_HEAP_SHA,
            'source_inputs_sha256': sha(json_bytes(inputs)),
            'source_diff_sha256': sha(output('git', '-C', source, 'diff', '--binary', 'HEAD')),
            'source_inputs': inputs}


def save_artifact(source, dll, method, extra):
    validate_source(source, True)
    validate_pe(dll)
    record = source_record(source)
    inputs = record.pop('source_inputs')
    manifest = {**record, **extra, 'format': 1, 'wine_version': '11.8', 'architecture': 'x86_64',
                'patch_sha256': sha(PATCH.read_bytes()), 'dll_sha256': sha(dll),
                'builder_sha256': sha(Path(__file__).read_bytes()), 'method': method,
                'license': 'LGPL-2.1-or-later', 'provenance': PROVENANCE,
                'scope': 'Process heap only; block-size 48 LFH shared-group retention threshold 4096.',
                'validation': 'Artifact packaging only; correctness/gameplay measurements are separate.'}
    write(OUT / 'source-inputs.json', json_bytes(inputs))
    write(OUT / 'ntdll.dll', dll)
    write(OUT / 'manifest.json', json_bytes(manifest))
    print('Prepared:', OUT / 'ntdll.dll')


def import_from_build(args):
    source = args.build_dir.resolve() / 'source'
    dll = (args.build_dir / 'ntdll-candidate.dll').read_bytes()
    if sha(dll) != TESTED_DLL_SHA:
        raise RuntimeError('Import accepts only the exact tested candidate; use build for a new artifact')
    evidence = {}
    for name in ('compile-control.sh', 'candidate-build.log', 'config.log'):
        evidence[name] = sha((args.build_dir / name).read_bytes())
    save_artifact(source, dll, 'import-tested-build', {'imported_build': str(args.build_dir.resolve()),
                                                    'build_evidence_sha256': evidence})


def build(args):
    source = OUT / 'source'
    build_dir = OUT / 'build'
    prefix = args.wine.resolve(strict=True)
    check_runtime(prefix)
    if not source.exists():
        validate_source(args.source, False)
        OUT.mkdir(parents=True, exist_ok=True)
        run('/bin/cp', '-cRp', args.source.resolve(), source)
        run('git', '-C', source, 'apply', '--check', PATCH)
        run('git', '-C', source, 'apply', PATCH)
    validate_source(source, True)
    build_dir.mkdir(parents=True, exist_ok=True)
    toolbin = OUT / 'toolbin'
    rust = Path(output('rustup', 'run', '1.98.0', 'rustc', '--print', 'sysroot').decode().strip())
    linker = rust / 'lib/rustlib/aarch64-apple-darwin/bin/rust-lld'
    wrapper = '#!/bin/sh\nexport DYLD_LIBRARY_PATH=' + shlex.quote(str(rust / 'lib')) + '\n'
    wrapper += 'exec ' + shlex.quote(str(linker)) + ' -flavor link "$@"\n'
    write(toolbin / 'lld-link', wrapper.encode(), 0o755)
    sdk = output('xcrun', '--show-sdk-path').decode().strip()
    cc = output('xcrun', '--find', 'clang').decode().strip() + ' -arch x86_64 -isysroot ' + shlex.quote(sdk)
    cxx = output('xcrun', '--find', 'clang++').decode().strip() + ' -arch x86_64 -isysroot ' + shlex.quote(sdk)
    env = dict(os.environ, LC_ALL='en_US.UTF-8', CC=cc, CXX=cxx, OBJC=cc,
               CFLAGS='-O2', CXXFLAGS='-O2', OBJCFLAGS='-O2', CROSSCFLAGS='-O2',
               PATH=f'{toolbin}:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/usr/bin:/bin:/opt/homebrew/bin:' + os.environ['PATH'],
               GNUTLS_CFLAGS='-I/opt/homebrew/opt/gnutls/include', GNUTLS_LIBS=f'-L{prefix}/lib -lgnutls',
               FREETYPE_CFLAGS='-I/opt/homebrew/opt/freetype/include/freetype2',
               FREETYPE_LIBS=f'-L{prefix}/lib -Wl,-rpath,{prefix}/lib -lfreetype',
               DYLD_FALLBACK_LIBRARY_PATH=f'{prefix}/lib:/usr/lib',
               ac_cv_lib_soname_gnutls='@loader_path/../../libgnutls.30.dylib',
               ac_cv_lib_soname_freetype='@loader_path/../../libfreetype.6.dylib')
    configure = [source / 'configure', '--host=x86_64-apple-darwin24', f'--prefix={prefix}',
                 '--enable-win64', '--with-mingw=/opt/homebrew/opt/llvm/bin/clang', '--disable-tests',
                 '--without-x', '--with-freetype', '--with-gnutls', '--without-vulkan',
                 '--without-gstreamer', '--without-ffmpeg']
    with (OUT / 'configure.log').open('wb') as log:
        run(*configure, cwd=build_dir, env=env, stdout=log, stderr=subprocess.STDOUT)
    with (OUT / 'compile.log').open('wb') as log:
        run('make', f'-j{args.jobs}', 'dlls/ntdll/x86_64-windows/ntdll.dll',
            cwd=build_dir, env=env, stdout=log, stderr=subprocess.STDOUT)
    save_artifact(source, (build_dir / 'dlls/ntdll/x86_64-windows/ntdll.dll').read_bytes(),
                  'isolated-build', {'configure_command': list(map(str, configure)),
                                     'clang_version': output('/opt/homebrew/opt/llvm/bin/clang', '--version').decode(),
                                     'linker_sha256': sha(linker.read_bytes())})


def safe_path(runtime, relative):
    path = runtime / relative
    if path.is_symlink() or runtime not in path.resolve().parents:
        raise RuntimeError('Refusing symlink or escaping runtime path: ' + str(path))
    return path


def check_runtime(runtime):
    path = safe_path(runtime, 'build-manifest.json')
    data = json.loads(path.read_bytes())
    if (data.get('wine_source_revision') != COMMIT or data.get('architecture') != 'x86_64'
            or data.get('wine_version') not in ('11.8', 'wine-11.8')):
        raise RuntimeError('Requires the pinned x86_64 WineGDK 11.8 runtime')
    for relative in (DLL, UNIX):
        if not safe_path(runtime, relative).is_file():
            raise RuntimeError('Missing target runtime module: ' + str(relative))
    return data


def refuse_active(runtime):
    result = subprocess.run(['/usr/sbin/lsof', '-Fpn', '--', str(runtime / DLL), str(runtime / UNIX)],
                            text=True, capture_output=True)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError('Could not establish whether the target runtime is active')
    if any(line.startswith('p') for line in result.stdout.splitlines()):
        raise RuntimeError('Close applications using the requested Wine runtime first')


@contextmanager
def runtime_lock(runtime):
    path = safe_path(runtime, '.wine-heap-reuse.lock')
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.write(fd, str(os.getpid()).encode())
        yield
    finally:
        os.close(fd)
        path.unlink()


def verified_artifact():
    data = (OUT / 'ntdll.dll').read_bytes()
    manifest = json.loads((OUT / 'manifest.json').read_bytes())
    expected = {'source_commit': COMMIT, 'heap_source_sha256': HEAP_SHA,
                'patch_sha256': sha(PATCH.read_bytes()), 'dll_sha256': sha(data),
                'architecture': 'x86_64', 'wine_version': '11.8', 'format': 1}
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise RuntimeError('Artifact provenance or checksum mismatch')
    inputs = json.loads((OUT / 'source-inputs.json').read_bytes())
    if sha(json_bytes(inputs)) != manifest['source_inputs_sha256']:
        raise RuntimeError('Source input manifest checksum mismatch')
    validate_pe(data)
    return data, manifest


def stage(args, restore=False):
    runtime = args.wine.resolve(strict=True)
    check_runtime(runtime)
    with runtime_lock(runtime):
        refuse_active(runtime)
        target = safe_path(runtime, DLL)
        metadata = safe_path(runtime, 'build-manifest.json')
        status = safe_path(runtime, STATUS)
        if restore:
            record = json.loads(status.read_bytes())
            previous = safe_path(runtime, record['backup']).read_bytes()
            old_manifest = safe_path(runtime, record['manifest_backup']).read_bytes()
            if sha(previous) != record['previous_sha256'] or sha(old_manifest) != record['previous_manifest_sha256']:
                raise RuntimeError('Backup checksum mismatch')
            if sha(target.read_bytes()) not in (record['dll_sha256'], record['previous_sha256']):
                raise RuntimeError('Target DLL changed since staging; refusing to overwrite')
            if sha(metadata.read_bytes()) not in (record['staged_manifest_sha256'], record['previous_manifest_sha256']):
                raise RuntimeError('Runtime manifest changed since staging; refusing to overwrite')
            write(target, previous, record['previous_mode'])
            write(metadata, old_manifest, record['previous_manifest_mode'])
            if target.read_bytes() != previous or metadata.read_bytes() != old_manifest:
                raise RuntimeError('Restore verification failed')
            status.unlink()
            print('Restored the previous ntdll.dll and exact runtime manifest.')
            return
        data, artifact = verified_artifact()
        if status.exists():
            record = json.loads(status.read_bytes())
            if (sha(target.read_bytes()) == artifact['dll_sha256'] == record.get('dll_sha256')
                    and sha(metadata.read_bytes()) == record.get('staged_manifest_sha256')):
                print('Already staged.')
                return
            raise RuntimeError('Restore the existing heap profile before staging another artifact')
        previous, old_manifest = target.read_bytes(), metadata.read_bytes()
        validate_pe(previous)
        if previous == data:
            raise RuntimeError('Candidate is already present without rollback metadata')
        backup_dir = Path(BACKUPS) / sha(previous)
        record = dict(artifact, previous_sha256=sha(previous), previous_manifest_sha256=sha(old_manifest),
                      previous_mode=stat.S_IMODE(target.stat().st_mode),
                      previous_manifest_mode=stat.S_IMODE(metadata.stat().st_mode),
                      backup=str(backup_dir / 'ntdll.dll'),
                      manifest_backup=str(backup_dir / ('build-manifest.' + sha(old_manifest) + '.json')))
        staged = json.loads(old_manifest)
        staged.setdefault('local_modifications', {})['heap_reuse'] = artifact
        staged_manifest = json_bytes(staged)
        record['staged_manifest_sha256'] = sha(staged_manifest)
        for name, contents in ((record['backup'], previous), (record['manifest_backup'], old_manifest)):
            backup = safe_path(runtime, name)
            if backup.exists() and backup.read_bytes() != contents:
                raise RuntimeError('Existing backup is corrupt')
            if not backup.exists():
                write(backup, contents)
        # Persist rollback information before either mutation. Restore accepts partial stages.
        write(status, json_bytes(record))
        write(target, data, record['previous_mode'])
        write(metadata, staged_manifest, record['previous_manifest_mode'])
        if sha(target.read_bytes()) != artifact['dll_sha256'] or metadata.read_bytes() != staged_manifest:
            raise RuntimeError('Stage verification failed; restore using the recorded backups')
        print('Staged the requested runtime Windows ntdll.dll; Unix modules are unchanged.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('build')
    p.add_argument('--source', type=Path, default=ROOT / 'build/standalone-wine/source')
    p.add_argument('--wine', type=Path, default=ROOT / 'runtime/standalone/wine')
    p.add_argument('--jobs', type=int, choices=range(1, 65), default=4)
    p = sub.add_parser('import-from-build')
    p.add_argument('--build-dir', type=Path, default=ROOT / 'build/performance/heap-build')
    for command in ('stage', 'restore'):
        p = sub.add_parser(command)
        p.add_argument('--wine', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'build':
        build(args)
    elif args.command == 'import-from-build':
        import_from_build(args)
    else:
        stage(args, args.command == 'restore')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
