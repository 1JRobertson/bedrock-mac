#!/bin/sh
# Stage the official, open-source DXMT release. No CrossOver files are used.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LC_ALL=en_US.UTF-8
exec /usr/bin/python3 - "$ROOT" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

root = Path(sys.argv[1])
parser = argparse.ArgumentParser(description='Stage pinned upstream DXMT binaries for standalone Wine.')
parser.add_argument('--wine-runtime', type=Path, help='Standalone Wine installation to receive DXMT; preserves original DLLs')
args = parser.parse_args(sys.argv[2:])
tag = 'v0.80'
commit = '589adb780354b461645b29999cefaf533594ee99'
assets = {
    'dxmt-v0.80-builtin.tar.gz': (
        'https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz',
        '8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d'),
    'dxmt-LICENSE.txt': (
        f'https://raw.githubusercontent.com/3Shain/dxmt/{commit}/LICENSE',
        '6b928413c6308c106f3e0080bd94b6427b56d587d400fd40e6cbfbab7d9c4ae1'),
    'dxmt-DXVK-LICENSE.txt': (
        f'https://raw.githubusercontent.com/3Shain/dxmt/{commit}/src/util/dxvk.LICENSE',
        '03ca4af84f5cd28cef3ed3f1ef4d17996992d35ccdbe82b29cc020ca02c16f3d'),
    'dxmt-LLVM-LICENSE.txt': (
        'https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-15.0.7/llvm/LICENSE.TXT',
        '8d85c1057d742e597985c7d4e6320b015a9139385cff4cbae06ffc0ebe89afee'),
    'dxmt-MinGW-LICENSE.txt': (
        'https://raw.githubusercontent.com/misyltoad/mingw-directx-headers/9df86f2341616ef1888ae59919feaa6d4fad693d/COPYING.MinGW-w64.txt',
        'f38e6194bd3bfa1b654f118e5acefe0aead437bbe669eee43957ccc65a7127f1'),
}
downloads = root / 'downloads'
stage = root / 'runtime/standalone/dxmt'
downloads.mkdir(exist_ok=True)
stage.mkdir(parents=True, exist_ok=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, 0o644)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

for name, (url, expected) in assets.items():
    path = downloads / name
    if not path.exists():
        fd, temporary = tempfile.mkstemp(prefix=f'.{name}.', dir=downloads)
        os.close(fd)
        try:
            subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--silent', '--show-error',
                            '--output', temporary, url], check=True)
            if digest(Path(temporary)) != expected:
                raise SystemExit(f'Hash mismatch: {name}')
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    if digest(path) != expected:
        raise SystemExit(f'Hash mismatch: {path}; refusing to stage changed input')

files = [f'x86_64-windows/{name}.dll' for name in ('d3d11', 'dxgi', 'd3d10core', 'winemetal')]
files += ['x86_64-unix/winemetal.so']
hashes = {}
with tarfile.open(downloads / 'dxmt-v0.80-builtin.tar.gz', 'r:gz') as archive:
    for name in files:
        entry = archive.getmember(f'{tag}/{name}')
        if not entry.isfile():
            raise SystemExit(f'Release entry is not a regular file: {name}')
        data = archive.extractfile(entry).read()
        if name.endswith('.dll') and b'Wine builtin DLL' not in data[:128]:
            raise SystemExit(f'Expected Wine builtin marker: {name}')
        atomic_write(stage / name, data)
        hashes[name] = hashlib.sha256(data).hexdigest()
for name in assets:
    if name.endswith('.txt'):
        atomic_write(stage / 'licenses' / name, (downloads / name).read_bytes())

runtime_links = {}
runtime_overlay = {}
if args.wine_runtime:
    wine = args.wine_runtime.resolve()
    if 'CrossOver.app' in wine.parts:
        raise SystemExit('Use the standalone Wine installation, not a CrossOver bundle')
    mapped_candidates = [wine / 'lib/wine' / name for name in files]
    mapped_candidates += [wine / 'lib/wine/x86_64-unix/winemetal-upstream.so']
    existing = [str(path) for path in mapped_candidates if path.exists()]
    if existing:
        mapped = subprocess.run(['/usr/sbin/lsof', '-Fpn', '--', *existing],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if mapped.returncode not in (0, 1) or mapped.stderr.strip():
            raise SystemExit('Cannot check mapped graphics files: ' + mapped.stderr.strip())
        pids = [line[1:] for line in mapped.stdout.splitlines() if line.startswith('p')]
        if pids:
            raise SystemExit('Graphics files are mapped by PID(s) ' + ', '.join(pids) + '; stop the target runtime first')
    for name in ('ntdll.so', 'winemac.so'):
        target = wine / 'lib/wine/x86_64-unix' / name
        if not target.is_file():
            raise SystemExit(f'Wine runtime component missing: {target}')
        link = stage / 'x86_64-unix' / name
        relative = os.path.relpath(target, link.parent)
        if link.is_symlink() and os.readlink(link) == relative:
            pass
        elif link.exists() or link.is_symlink():
            raise SystemExit(f'Refusing to overwrite existing runtime link: {link}')
        else:
            link.symlink_to(relative)
        runtime_links[name] = relative
    # Installed Wine searches its own DLL directory before WINEDLLPATH. Place
    # DXMT there too, keeping the exact upstream bytes and backing up each
    # displaced Wine build. Re-running after `make install` restores DXMT.
    for name in files:
        target = wine / 'lib/wine' / name
        expected = hashes[name]
        backup = None
        if target.is_file() and digest(target) != expected:
            original_hash = digest(target)
            backup = stage / 'wine-originals' / f'{name}.{original_hash}'
            if not backup.exists():
                atomic_write(backup, target.read_bytes())
        if not target.is_file() or digest(target) != expected:
            atomic_write(target, (stage / name).read_bytes())
        runtime_overlay[name] = {'sha256': expected}
        if backup:
            runtime_overlay[name]['backup'] = str(backup.relative_to(stage))
    if any(digest(wine / 'lib/wine' / name) != hashes[name] for name in files):
        raise SystemExit('Installed graphics verification failed; optional bridge manifests retained')
    # The official entry library no longer uses either optional adapter. Only
    # clear their manifests after every restored file has passed verification.
    for optional in ('dxmt-unix-bridge.json', 'dxmt-pool-adapter.json'):
        (wine / optional).unlink(missing_ok=True)

manifest = {
    'component': 'DXMT', 'version': tag, 'source_commit': commit,
    'source_url': f'https://github.com/3Shain/dxmt/tree/{commit}',
    'license': 'MIT (this pinned version); bundled notices in licenses/',
    'minimum_macos': '15.0', 'architecture': 'x86_64 (Rosetta on Apple Silicon)',
    'apis': ['Direct3D 10', 'Direct3D 11'], 'supports_d3d12': False,
    'wine_dll_path': '.', 'dll_overrides': 'd3d11,dxgi,d3d10core,winemetal=b',
    'assets': {name: {'url': url, 'sha256': sha} for name, (url, sha) in assets.items()},
    'files': hashes, 'runtime_links': runtime_links, 'runtime_overlay': runtime_overlay,
    'verification': 'Release bytes and builtin markers verified; gameplay requires a separate test.',
}
atomic_write(stage / 'manifest.json', (json.dumps(manifest, indent=2) + '\n').encode())
print(f'Staged upstream DXMT {tag}: {stage}')
print('Use WINEDLLPATH=<stage> and WINEDLLOVERRIDES=d3d11,dxgi,d3d10core,winemetal=b')
if not args.wine_runtime:
    print('Run again with --wine-runtime <standalone Wine install> to deploy DXMT into it.')
PY
