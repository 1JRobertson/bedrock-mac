#!/usr/bin/env python3
"""Validate and explicitly stage the isolated, pinned DXMT Unix rebuild."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / 'build/dxmt-memory-unix'
COMMIT = '589adb780354b461645b29999cefaf533594ee99'
UPSTREAM_SHA = '3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca'
FILES = ('winemetal.so', 'winemetal-upstream.so')
HEADERS = ('src/winemetal/winemetal_thunks.h', 'src/winemetal/winemetal.h',
           'src/winemetal/airconv_thunks.h', 'src/airconv/airconv_public.h')
SOURCE_FIELDS = ('source_commit', 'patch_sha256', 'trace_source_sha256',
                 'input_header_sha256', 'upstream_source_sha256', 'patched_source_sha256')
PROBES = {
    'standalone-graphics-probe': ('HardwareDeviceAndSwapChain=0x00000000',
        'GPUReadback=0x00000000', 'RedPixel=0xFF0000FF', 'HiddenPresent=0x00000000'),
    'standalone-graphics-shader-probe': ('HardwareDevice=0x00000000',
        'ShaderTextureReadback=0x00000000', 'ShaderDiscardReadback=0x00000000'),
}


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def source_metadata():
    tree = ROOT / 'sources/dxmt'
    source = 'src/winemetal/unix/winemetal_unix.c'
    for name in (source,) + HEADERS:
        pinned = subprocess.check_output(['git', '-C', str(tree), 'show', f'{COMMIT}:{name}'])
        if (tree / name).read_bytes() != pinned:
            raise RuntimeError(f'Input differs from pinned source: {name}')
    patched = OUTPUT / 'source' / source
    text = patched.read_text()
    if text.count('CFRelease(tag_data);') != 3 or 'bool got_gamut' not in text or text.count('@autoreleasepool') != 2:
        raise RuntimeError('Expected memory-lifetime fixes are absent')
    return {
        'source_commit': COMMIT,
        'patch_sha256': digest(ROOT / 'patches/standalone-dxmt-memory-lifetime.patch'),
        'trace_source_sha256': digest(ROOT / 'standalone-dxmt-display-trace.c'),
        'input_header_sha256': {name: digest(tree / name) for name in HEADERS},
        'upstream_source_sha256': digest(tree / source),
        'patched_source_sha256': digest(patched),
    }


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def manifest():
    data = {'version': 'v0.80', 'status': 'Experimental Unix-only rebuild; not installed.',
        'fixes': ['display query autorelease pool', 'output description autorelease pool',
                  'ColorSync profile/tag releases'],
        'excluded_fixes': ['C++ finish-thread autorelease pool'],
        'files': {name: digest(OUTPUT / name) for name in FILES}, **source_metadata()}
    if data['files']['winemetal-upstream.so'] != UPSTREAM_SHA:
        raise RuntimeError('Upstream shader library changed')
    write_json(OUTPUT / 'unix-bridge-manifest.json', data)
    return data


def verified_output(require_tests=False):
    data = json.loads((OUTPUT / 'unix-bridge-manifest.json').read_text())
    current = source_metadata()
    if data.get('version') != 'v0.80' or any(data.get(key) != current[key] for key in SOURCE_FIELDS):
        raise RuntimeError('Build inputs changed; rebuild and validate again')
    if set(data.get('files', {})) != set(FILES) or data['files']['winemetal-upstream.so'] != UPSTREAM_SHA:
        raise RuntimeError('Unexpected output manifest')
    for name in FILES:
        if digest(OUTPUT / name) != data['files'][name]:
            raise RuntimeError(f'Built artifact changed: {name}')
    if require_tests:
        validation = json.loads((OUTPUT / 'render-validation.json').read_text())
        if validation.get('files') != data['files'] or any(validation.get(key) != data[key] for key in SOURCE_FIELDS):
            raise RuntimeError('Render validation does not match this exact build')
        if set(validation.get('passed_probes', [])) != set(PROBES):
            raise RuntimeError('Both graphics probes must pass before staging')
        data['render_validation'] = validation
    return data


def refuse_mapped(paths):
    existing = [str(path) for path in paths if path.exists()]
    if not existing:
        return
    result = subprocess.run(['/usr/sbin/lsof', '-Fpn', '--', *existing],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError('Cannot establish whether target libraries are mapped: ' + result.stderr.strip())
    pids = [line[1:] for line in result.stdout.splitlines() if line.startswith('p')]
    if pids:
        raise RuntimeError('Target libraries are mapped by PID(s) ' + ', '.join(pids) + '; stop that runtime first')


def stage(runtime):
    data = verified_output(require_tests=True)
    runtime = Path(runtime).resolve(strict=True)
    directory = runtime / 'lib/wine/x86_64-unix'
    targets = [directory / name for name in FILES]
    metadata_path = runtime / 'dxmt-unix-bridge.json'
    if not (runtime / 'bin/wine').is_file() or not targets[0].is_file():
        raise RuntimeError('Expected an existing standalone Wine runtime with DXMT installed')
    for path in targets + [metadata_path]:
        if path.is_symlink() or runtime not in path.resolve().parents:
            raise RuntimeError(f'Refusing a symlink or escaping target: {path}')
    refuse_mapped(targets)
    current = digest(targets[0])
    if current != UPSTREAM_SHA:
        previous = json.loads(metadata_path.read_text()) if metadata_path.exists() else {}
        if previous.get('files', {}).get('winemetal.so') != current:
            raise RuntimeError('Refusing to replace an unrecognized winemetal.so')
    backup = runtime / 'dxmt-unix-bridge-backups' / UPSTREAM_SHA / 'winemetal.so'
    backup.parent.mkdir(parents=True, exist_ok=True)
    if backup.exists() and digest(backup) != UPSTREAM_SHA:
        raise RuntimeError('Original-library backup is corrupt')
    if not backup.exists():
        fd, temporary = tempfile.mkstemp(prefix='.original-', dir=backup.parent)
        os.close(fd)
        try:
            shutil.copy2(OUTPUT / 'winemetal-upstream.so', temporary)
            if digest(temporary) != UPSTREAM_SHA:
                raise RuntimeError('Original-library backup verification failed')
            os.replace(temporary, backup)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    transaction = Path(tempfile.mkdtemp(prefix='.dxmt-stage-', dir=runtime))
    committed, saved, rollback_errors = [], {}, []
    destinations = targets + [metadata_path]
    try:
        for i, path in enumerate(destinations):
            saved[path] = transaction / f'saved-{i}' if path.exists() else None
            if saved[path] is not None: shutil.copy2(path, saved[path])
        for name in FILES:
            shutil.copy2(OUTPUT / name, transaction / name)
            if digest(transaction / name) != data['files'][name]:
                raise RuntimeError('Prepared artifact verification failed')
        data.update(status='Experimental Unix bridge explicitly staged.',
                    original_backup=str(backup.relative_to(runtime)))
        write_json(transaction / metadata_path.name, data)
        refuse_mapped(targets)
        # Dependency first, entry library second, manifest last.
        for path in (targets[1], targets[0], metadata_path):
            os.replace(transaction / path.name, path)
            committed.append(path)
        for name in FILES:
            if digest(directory / name) != data['files'][name]:
                raise RuntimeError('Installed artifact verification failed')
    except BaseException as error:
        for path in reversed(committed):
            try:
                if saved[path] is None: path.unlink()
                else: os.replace(saved[path], path)
            except OSError as rollback_error:
                rollback_errors.append(str(rollback_error))
        if rollback_errors:
            raise RuntimeError(f'{error}; rollback incomplete: {rollback_errors}; backups retained at {transaction}') from error
        raise
    finally:
        if not rollback_errors: shutil.rmtree(transaction)
    print(f'Staged verified Unix bridge into {runtime}')


def validate_runtime(runtime, prefix=None):
    data = verified_output()
    runtime = Path(runtime).resolve(strict=True)
    directory = runtime / 'lib/wine/x86_64-unix'
    for name in FILES:
        if digest(directory / name) != data['files'][name]:
            raise RuntimeError('Test runtime differs from built output')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('CX_', 'WINE', 'DYLD_', 'BEDROCK_GRAPHICS_', 'BEDROCK_DXMT_'))}
    prefix = prefix or ROOT / 'runtime/standalone-graphics-validation-prefix'
    env.update(WINEPREFIX=str(prefix), WINEARCH='win64',
        WINEDLLOVERRIDES='mscoree,mshtml=;winemenubuilder.exe=d;d3d11,dxgi,d3d10core,winemetal=b',
        WINEDEBUG='-all', LC_ALL='en_US.UTF-8', DXMT_LOG_LEVEL='error', DXMT_LOG_PATH=str(OUTPUT))
    for probe, expected in PROBES.items():
        with (OUTPUT / f'validated-{probe}.log').open('w') as log:
            result = subprocess.run([str(runtime / 'bin/wine'), str(ROOT / f'runtime/standalone/probes/{probe}.exe')],
                env=env, stdout=log, stderr=subprocess.STDOUT, timeout=55)
        text = (OUTPUT / f'validated-{probe}.log').read_text()
        if result.returncode or any(line not in text for line in expected):
            raise RuntimeError(f'Render validation failed: {probe}')
    for name in FILES:
        if digest(directory / name) != data['files'][name] or digest(OUTPUT / name) != data['files'][name]:
            raise RuntimeError('Artifacts changed during validation')
    record = {key: data[key] for key in SOURCE_FIELDS}
    record.update(files=data['files'], passed_probes=list(PROBES))
    write_json(OUTPUT / 'render-validation.json', record)
    print('Both render probes passed for the recorded output pair.')


def validate_clone(base):
    """Place unvalidated bytes only in a disposable private test runtime."""
    data = verified_output()
    base = Path(base).resolve(strict=True)
    if not (base / 'bin/wine').is_file():
        raise RuntimeError('Expected a built standalone Wine runtime')
    directory = Path(tempfile.mkdtemp(prefix='.dxmt-validation-', dir=ROOT / 'runtime'))
    runtime = directory / 'wine'
    try:
        subprocess.run(['/bin/cp', '-cR', str(base), str(runtime)], check=True)
        target = runtime / 'lib/wine/x86_64-unix'
        for name in FILES:
            shutil.copy2(OUTPUT / name, target / name)
            if digest(target / name) != data['files'][name]:
                raise RuntimeError('Test artifact copy verification failed')
        validate_runtime(runtime, directory / 'prefix')
    finally:
        server = runtime / 'bin/wineserver'
        if server.exists():
            env = dict(os.environ, WINEPREFIX=str(directory / 'prefix'))
            subprocess.run([str(server), '-k'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            subprocess.run([str(server), '-w'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        shutil.rmtree(directory)


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['manifest']: manifest()
        elif len(sys.argv) == 3 and sys.argv[1] == 'stage': stage(sys.argv[2])
        elif len(sys.argv) == 3 and sys.argv[1] == 'validate': validate_runtime(sys.argv[2])
        elif len(sys.argv) == 3 and sys.argv[1] == 'validate-clone': validate_clone(sys.argv[2])
        else: raise RuntimeError('Expected manifest, stage RUNTIME, validate RUNTIME, or validate-clone BASE_RUNTIME')
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'DXMT Unix bridge: {error}', file=sys.stderr)
        sys.exit(1)
