#!/usr/bin/env python3
"""Reconstruct the selected release runtime in a new, source-only workspace."""
import argparse
import ast
from contextlib import contextmanager
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import types

ROOT = Path(__file__).resolve().parent
PROFILE = 'release-runtime-profile.json'
RECEIPT = 'release-runtime-state.json'


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def read(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise RuntimeError('Expected a JSON object: ' + path.name)
    return value


def write(path, value):
    temporary = path.with_name(path.name + '.new')
    with temporary.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
    os.replace(temporary, path)


def relative_path(name):
    path = Path(name)
    if path.is_absolute() or '..' in path.parts or str(path) != name or not name:
        raise RuntimeError('Unsafe manifest path')
    return path


def contained(root, name):
    root = root.resolve(strict=True)
    path = root / relative_path(name)
    if not path.resolve().is_relative_to(root):
        raise RuntimeError('Manifest path escapes its root')
    return path


def verify_profile(source):
    profile = read(source / PROFILE)
    for name, expected in profile['source_files'].items():
        path = contained(source, name)
        if path.is_symlink() or digest(path) != expected:
            raise RuntimeError('Selected source input changed: ' + name)
    actual = {p.name for p in (source / 'patches').glob('standalone-wine-*.patch')}
    if actual != set(profile['wine_standalone_patches']):
        raise RuntimeError('Wine builder patch set differs from selected release profile')
    tree = ast.parse((source / 'bootstrap-sources.py').read_text())
    projects = next(ast.literal_eval(node.value) for node in tree.body
                    if isinstance(node, ast.Assign)
                    and any(isinstance(target, ast.Name) and target.id == 'PROJECTS' for target in node.targets))
    for name, pinned in profile['upstream'].items():
        if any(projects[name][key] != pinned[key] for key in ('url', 'commit')):
            raise RuntimeError('Bootstrap differs from pinned upstream: ' + name)
    return profile


def verify_source_snapshot(source):
    if source.is_symlink():
        raise RuntimeError('Workspace source directory must not be a symlink')
    inventory = source / 'SOURCE-SHA256.txt'
    for line in inventory.read_text().splitlines():
        expected, name = line.split('  ', 1)
        path = contained(source, name)
        if path.is_symlink() or digest(path) != expected:
            raise RuntimeError('Exported source changed: ' + name)
    return digest(inventory)


def prepare(workspace):
    verify_profile(ROOT)
    exporter = types.ModuleType('release_export')
    exporter.__file__ = str(ROOT / 'export-source.py')
    exec(compile((ROOT / 'export-source.py').read_bytes(), exporter.__file__, 'exec'), exporter.__dict__)
    if not {'build-release-runtime.py', PROFILE, 'tests/test_release_runtime.py',
            'build-native-dependencies.py', 'native-dependencies.lock.json'}.issubset(exporter.ALLOWED_FILES):
        raise RuntimeError('Release driver files must be reviewed into the source export allowlist first')
    workspace = workspace.absolute()
    if workspace.exists() or workspace.is_symlink():
        raise RuntimeError('Choose a new workspace; existing output is never reused by prepare')
    workspace.mkdir()
    exporter.export_sources(ROOT, workspace / 'source')
    verify_profile(workspace / 'source')
    state = {'schema': 1, 'phase': 'prepared', 'source_sha256': verify_source_snapshot(workspace / 'source'),
             'profile_sha256': digest(workspace / 'source' / PROFILE), 'build_executed': False,
             'graphics_validation_executed': False, 'gameplay_validated': False}
    write(workspace / RECEIPT, state)
    return state


def verify_dependencies(prefix):
    if prefix is None:
        raise RuntimeError('Source-built native dependency prefix is required; Gcenx binary provenance is unresolved')
    prefix = prefix.resolve(strict=True)
    manifest = read(prefix / 'dependency-manifest.json')
    if (manifest.get('schema') != 1 or manifest.get('source_built') is not True
            or manifest.get('architecture') != 'x86_64' or not manifest.get('source_archives')
            or not manifest.get('build_commands') or not manifest.get('tool_versions')):
        raise RuntimeError('Native dependency source/build provenance is incomplete')
    for archive in manifest['source_archives']:
        if not archive.get('url', '').startswith('https://') or not re.fullmatch(r'[0-9a-f]{64}', archive.get('sha256', '')):
            raise RuntimeError('Native dependency source archive is not pinned')
    files = manifest.get('files', {})
    for name, record in files.items():
        path = contained(prefix, name)
        if path.is_symlink():
            if not isinstance(record, dict) or str(path.readlink()) != record.get('symlink') or not path.resolve().is_relative_to(prefix):
                raise RuntimeError('Native dependency link is unverified')
            target = str(path.resolve().relative_to(prefix))
            if target not in files or not path.is_file():
                raise RuntimeError('Native dependency link target bytes are unrecorded')
        else:
            expected = record.get('sha256') if isinstance(record, dict) else record
            if not path.is_file() or digest(path) != expected:
                raise RuntimeError('Native dependency bytes differ from their receipt')
    for name in ('lib/libgnutls.30.dylib', 'lib/libfreetype.6.dylib', 'include/gnutls/gnutls.h', 'include/freetype2/ft2build.h'):
        if name not in files or not (prefix / name).is_file():
            raise RuntimeError('Native dependency closure or matching headers are missing')
    return digest(prefix / 'dependency-manifest.json')


def commands(source, python, toolchain, build_python, jobs):
    wine = source / 'runtime/standalone/wine'
    return [
        [python, 'bootstrap-sources.py', '--project', 'winegdk'],
        [python, 'bootstrap-sources.py', '--project', 'dxmt'],
        ['/bin/sh', 'build-standalone-wine.sh'],
        ['/bin/sh', 'build-standalone-graphics.sh', '--wine-runtime', str(wine)],
        [python, 'standalone-wine-heap.py', 'build', '--wine', str(wine), '--jobs', str(jobs)],
        [python, 'standalone-wine-heap.py', 'stage', '--wine', str(wine)],
        [python, 'standalone-dxmt-shared.py', 'build', '--reuse-input-layout', '--toolchain', str(toolchain), '--python', str(build_python), '--jobs', str(jobs)],
        [python, 'standalone-dxmt-shared.py', 'stage', '--reuse-input-layout', '--wine', str(wine), '--dxmt', str(source / 'runtime/standalone/dxmt')],
        ['/bin/sh', 'build-standalone-dxmt-unix.sh'],
        ['/bin/sh', 'build-standalone-probes.sh'],
    ]


@contextmanager
def slot(root, name, owner_thread='manual-release-runtime'):
    if root is None:
        raise RuntimeError('Pass the shared --locks directory for build or graphics validation')
    other = 'interactive' if name == 'heavy-build' else 'heavy-build'
    if (root / other).exists():
        raise RuntimeError('Another build or interactive test owns the shared slot')
    lock = root / name
    lock.mkdir(exist_ok=False)
    owner = {'pid': os.getpid(), 'thread_id': owner_thread, 'purpose': 'release runtime ' + name,
             'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    try:
        write(lock / 'owner.json', owner)
        if (root / other).exists():
            raise RuntimeError('Another shared-slot owner appeared; retry when idle')
        yield
    finally:
        try:
            ours = read(lock / 'owner.json') == owner
        except (OSError, ValueError, RuntimeError):
            ours = False
        if ours:
            (lock / 'owner.json').unlink()
            lock.rmdir()


def run_steps(steps, source, logs, env):
    logs.mkdir(exist_ok=False)
    results = []
    for number, command in enumerate(steps, 1):
        name = f'{number:02d}.log'
        with (logs / name).open('wb') as output:
            completed = subprocess.run(command, cwd=source, env=env, stdout=output, stderr=subprocess.STDOUT)
        results.append({'argv': command, 'exit_code': completed.returncode, 'log': name, 'log_sha256': digest(logs / name)})
        write(logs / 'steps.json', results)
        if completed.returncode:
            raise RuntimeError('Build/validation step failed; inspect ' + str(logs / name))
    return results


def host_tool_evidence():
    evidence = {'python': sys.version}
    for name, command in {
        'sdk': ['xcrun', '--show-sdk-version'],
        'apple_clang': ['xcrun', 'clang', '--version'],
        'llvm': ['/opt/homebrew/opt/llvm/bin/clang', '--version'],
        'bison': ['/opt/homebrew/opt/bison/bin/bison', '--version'],
        'rust': ['rustup', 'run', '1.98.0', 'rustc', '--version'],
    }.items():
        evidence[name] = subprocess.check_output(command, text=True, timeout=15,
                                                 env=build_environment()).strip()
    return evidence


def build_environment():
    # The profile owns compiler flags. Shell overrides such as CXXFLAGS,
    # CPATH, SDKROOT, or PKG_CONFIG_PATH must not alter an unrecorded build.
    home = str(Path.home())
    env = {'HOME': home, 'LC_ALL': 'en_US.UTF-8',
           'PATH': ':'.join((str(Path(home) / '.cargo/bin'), '/opt/homebrew/bin',
                             '/usr/bin', '/bin', '/usr/sbin', '/sbin'))}
    # These locate tool installations; their actual versions are recorded.
    for name in ('RUSTUP_HOME', 'CARGO_HOME', 'DEVELOPER_DIR', 'TMPDIR'):
        if name in os.environ:
            env[name] = os.environ[name]
    return env


def build(args, state, profile):
    source = args.workspace / 'source'
    if state.get('phase') != 'prepared' or state.get('build_executed') is not False:
        raise RuntimeError('Build requires a fresh prepared workspace')
    for name in ('sources', 'build', 'runtime', 'downloads'):
        if (source / name).exists() or (source / name).is_symlink():
            raise RuntimeError('Build requires fresh generated directories; prepare a new workspace')
    dependency_sha = verify_dependencies(args.dependencies)
    # This guard deliberately blocks until the Wine builder supports the audited
    # source dependency prefix. Never silently fall back to binary-only inputs.
    if 'STANDALONE_DEPENDENCY_PREFIX' not in (source / 'build-standalone-wine.sh').read_text():
        raise RuntimeError('Wine builder native source-dependency integration is not ready')
    if args.toolchain_archive is None or digest(args.toolchain_archive) != profile['toolchain']['sha256']:
        raise RuntimeError('Provide the pinned llvm-mingw toolchain archive')
    if args.build_python is None:
        raise RuntimeError('Provide a Python venv with the pinned Meson and Ninja versions')
    versions = {}
    for name, expected in profile['build_python_packages'].items():
        executable = args.build_python / 'bin' / name
        version = subprocess.check_output([str(executable), '--version'], text=True,
                                          env=build_environment()).strip()
        if version != expected and not (name == 'ninja' and version.startswith(expected + '.')):
            raise RuntimeError('Build tool version differs from profile: ' + name)
        versions[name] = version
    with slot(args.locks, 'heavy-build', args.owner_thread):
        tools = args.workspace / 'toolchain'
        tools.mkdir(exist_ok=False)
        subprocess.run(['/usr/bin/tar', '-xf', str(args.toolchain_archive.resolve()), '-C', str(tools)], check=True)
        toolchain = tools / profile['toolchain']['directory']
        if not (toolchain / 'bin/x86_64-w64-mingw32-clang++').is_file():
            raise RuntimeError('Pinned toolchain archive has unexpected contents')
        env = build_environment()
        env.update(STANDALONE_JOBS=str(args.jobs), STANDALONE_DEPENDENCY_PREFIX=str(args.dependencies.resolve()))
        write(args.workspace / 'build-environment.json', env)
        host_tools = host_tool_evidence()
        write(args.workspace / 'host-tools.json', host_tools)
        steps = commands(source, sys.executable, toolchain, args.build_python.resolve(), args.jobs)
        state.update(phase='building', build_attempted=True)
        write(args.workspace / RECEIPT, state)
        try:
            run_steps(steps, source, args.workspace / 'build-logs', env)
        except BaseException:
            state.update(phase='build_failed', build_executed=False)
            write(args.workspace / RECEIPT, state)
            raise
        state.update(phase='built_pending_graphics_validation', build_executed=True,
                     native_dependency_manifest_sha256=dependency_sha, build_tool_versions=versions,
                     toolchain_archive_sha256=profile['toolchain']['sha256'],
                     host_tools_sha256=digest(args.workspace / 'host-tools.json'),
                     build_environment_sha256=digest(args.workspace / 'build-environment.json'))
        write(args.workspace / RECEIPT, state)
    return state


def validate(args, state):
    if state.get('build_executed') is not True or state.get('phase') != 'built_pending_graphics_validation':
        raise RuntimeError('Complete this workspace build before graphics validation')
    processes = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
    if any(line.lower().endswith(('\\minecraft.windows.exe', '/minecraft.windows.exe')) for line in processes.splitlines()):
        raise RuntimeError('Quit Minecraft normally before candidate graphics validation')
    source = args.workspace / 'source'
    contained(source, 'runtime/standalone/wine')
    with slot(args.locks, 'interactive', args.owner_thread):
        steps = [[sys.executable, 'standalone-dxmt-unix.py', 'validate-clone', str(source / 'runtime/standalone/wine')],
                 [sys.executable, 'standalone-dxmt-unix.py', 'stage', str(source / 'runtime/standalone/wine')]]
        env = build_environment()
        try:
            run_steps(steps, source, args.workspace / 'graphics-logs', env)
        except BaseException:
            state.update(phase='graphics_validation_failed', graphics_validation_executed=False)
            write(args.workspace / RECEIPT, state)
            raise
        state.update(phase='graphics_validated_gameplay_pending', graphics_validation_executed=True)
        write(args.workspace / RECEIPT, state)
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('plan', 'prepare', 'build', 'validate'))
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--dependencies', type=Path)
    parser.add_argument('--toolchain-archive', type=Path)
    parser.add_argument('--build-python', type=Path)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=2)
    parser.add_argument('--locks', type=Path)
    parser.add_argument('--owner-thread', default='manual-release-runtime')
    args = parser.parse_args()
    args.workspace = args.workspace.absolute()
    if args.action == 'plan':
        print(json.dumps(verify_profile(ROOT), indent=2))
        return
    if args.action == 'prepare':
        state = prepare(args.workspace)
    else:
        source = args.workspace / 'source'
        state = read(args.workspace / RECEIPT)
        if verify_source_snapshot(source) != state.get('source_sha256'):
            raise RuntimeError('Workspace source inventory differs from its preparation receipt')
        profile = verify_profile(source)
        state = build(args, state, profile) if args.action == 'build' else validate(args, state)
    print(json.dumps(state, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
