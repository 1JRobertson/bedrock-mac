#!/usr/bin/env python3
"""Stage small pinned downloads and an independent APFS Wine clone; no game launch."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

BASE = Path(__file__).absolute().parent
CLIENT = Path(os.environ.get('MULLION_CLIENT_ROOT', BASE.parents[1])).resolve()
CLIENT_SCRIPTS = CLIENT / 'client' if (CLIENT / 'client/standalone.py').is_file() else CLIENT
TAG = 'v0.3'
SOURCE_COMMIT = '5dda0b9af63dd246003a9ee9f84fd738b81867f9'
SHA = 'c7f97f29cd9bcb5e2aaf776ffa9e84adfe566399e91fccd78c089e1ea27bdfe9'
DXC_SHA = 'ad31b1fc8443175d204f77a611fdb3ef2ec42759bdc2f1167368de24a4a7e7f1'
GUARD = next((p / 'tools/qa_resource_guard.py' for p in reversed((BASE.parents[1], *BASE.parents[1].parents))
              if (p / 'tools/qa_resource_guard.py').is_file()), BASE.parents[1] / 'tools/qa_resource_guard.py')


def writable_path(path):
    if not path.is_relative_to(BASE):
        raise RuntimeError('Stage write escapes the experiment.')
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise RuntimeError('Unexpected stage symlink: ' + str(parent))
    return path


def safe_paths():
    # Run before even opening the guard log, not just before native work.
    for name in ('downloads', 'logs', 'dxc', 'source', 'mullion-v0.3', 'wine',
                 'versions.json', 'logs/stage.log', 'downloads/mullion-v0.3.tar.gz',
                 'downloads/dxc_2026_09_29.zip', 'dxc/dxc.exe',
                 'dxc/dxcompiler.dll', 'dxc/dxil.dll'):
        writable_path(BASE / name)
    wine = BASE / 'wine'
    for path in wine.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(wine):
            raise RuntimeError('Wine symlink escapes experiment.')


def require_idle():
    wine = BASE / 'wine'
    mapped = [wine / name for name in ('bin/wine', 'bin/wineserver',
              'lib/wine/x86_64-unix/wine', 'lib/wine/x86_64-unix/ntdll.so')
              if (wine / name).exists()]
    if not mapped:
        return
    result = subprocess.run(['/usr/sbin/lsof', '-t', *map(str, mapped)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=15)
    if result.returncode == 0:
        raise RuntimeError('Close the experimental game and Wine processes before staging; live runtime preserved.')
    if result.returncode != 1 or result.stderr:
        raise RuntimeError('Cannot verify that the experimental Wine runtime is idle.')


def write_bytes(path, content):
    writable_path(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.' + path.name + '-',
                                         delete=False) as output:
            temporary = Path(output.name)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def download(url, path, limit):
    writable_path(path)
    if path.exists():
        if not path.is_file():
            raise RuntimeError('Download cache is not a regular file.')
        return
    temporary = None
    size = 0
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.' + path.name + '-',
                                         suffix='.partial', delete=False) as output:
            temporary = Path(output.name)
            with urllib.request.urlopen(url, timeout=60) as response:
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > limit:
                        raise RuntimeError('Download exceeds reviewed size bound.')
                    output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def stage():
    os.umask(0o077)
    safe_paths()
    require_idle()
    for name in ('downloads', 'logs', 'dxc'):
        path = BASE / name
        if path.is_symlink():
            raise RuntimeError('Unexpected stage symlink.')
        path.mkdir(exist_ok=True, mode=0o700)
    archive = BASE / 'downloads/mullion-v0.3.tar.gz'
    download(f'https://github.com/dttdrv/mullion/releases/download/{TAG}/mullion-{TAG}.tar.gz',
             archive, 20 * 1024**2)
    if digest(archive) != SHA:
        raise RuntimeError('Mullion archive hash mismatch.')
    release = BASE / 'mullion-v0.3'
    if release.is_symlink():
        raise RuntimeError('Release directory must not be linked.')
    if not release.exists():
        with tarfile.open(archive) as package:
            for item in package.getmembers():
                target = (BASE / item.name).resolve()
                if not target.is_relative_to(BASE) or not (item.isfile() or item.isdir()):
                    raise RuntimeError('Unexpected archive member.')
            package.extractall(BASE)
    source_tree = BASE / 'source'
    if source_tree.is_symlink():
        raise RuntimeError('Shader source directory must not be linked.')
    if not source_tree.exists():
        subprocess.run(['git', 'clone', '--filter=blob:none', '--no-checkout',
                        'https://github.com/dttdrv/mullion.git', str(source_tree)], check=True)
        subprocess.run(['git', '-C', str(source_tree), 'checkout', '--detach', SOURCE_COMMIT], check=True)
    actual = subprocess.check_output(['git', '-C', str(source_tree), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != SOURCE_COMMIT:
        raise RuntimeError('Existing Mullion shader sources do not match the pinned commit.')
    changes = subprocess.check_output(['git', '-C', str(source_tree), 'status', '--porcelain',
                                       '--untracked-files=all'], text=True)
    if changes:
        raise RuntimeError('Pinned Mullion shader source has local changes; preserve them and use a clean checkout.')
    wine = BASE / 'wine'
    if wine.is_symlink():
        raise RuntimeError('Wine must be independent.')
    wine.mkdir(exist_ok=True)
    source = CLIENT / 'runtime/standalone/wine'
    # Never copy the working bottle. CoW copies share storage, not file inodes.
    for name in ('bin', 'lib', 'share', 'include'):
        if not (wine / name).exists():
            subprocess.run(['/bin/cp', '-cR', str(source / name), str(wine / name)], check=True)
    for path in wine.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(wine):
            raise RuntimeError('Wine symlink escapes experiment.')
    subprocess.run(['/bin/sh', str(release / 'install.sh'), str(wine)], check=True)
    dxc = BASE / 'downloads/dxc_2026_09_29.zip'
    download('https://github.com/microsoft/DirectXShaderCompiler/releases/download/'
             'v1.9.2609/dxc_2026_09_29.zip', dxc, 40 * 1024**2)
    if digest(dxc) != DXC_SHA:
        raise RuntimeError('DXC archive hash mismatch.')
    with zipfile.ZipFile(dxc) as package:
        for name in ('dxc.exe', 'dxcompiler.dll', 'dxil.dll'):
            write_bytes(BASE / 'dxc' / name, package.read('bin\\x64\\' + name))
    record = {
        'mullion': TAG, 'mullion_commit': '5dda0b9af63dd246003a9ee9f84fd738b81867f9',
        'archive_sha256': SHA, 'wine': 'WineGDK 11.8; independent APFS copy',
        'wine_loader_sha256': digest(wine / 'bin/wine'),
        'dxc': 'v1.9.2609', 'dxc_archive_sha256': digest(dxc),
        'mullion_dll_sha256': {p.name: digest(p) for p in (release / 'x86_64-windows').glob('*.dll')},
        'production_baseline': {str(p.relative_to(CLIENT)): digest(p) for p in [
            CLIENT_SCRIPTS / 'standalone.py', source / 'bin/wine',
            source / 'lib/wine/x86_64-windows/d3d11.dll',
            source / 'lib/wine/x86_64-unix/winemetal.so']}}
    write_bytes(BASE / 'versions.json', (json.dumps(record, indent=2) + '\n').encode())
    print('Mullion staged in experimental Wine; production runtime and bottle untouched.')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    safe_paths()
    if args.worker:
        stage()
        return 0
    # The guard holds the same exclusive job lock as run.py throughout copying,
    # downloading and renderer installation. Never stage beside an active game.
    return subprocess.call([sys.executable, str(GUARD), '--log', str(BASE / 'logs/stage.log'),
                            '--', sys.executable, '-B', str(Path(__file__).absolute()), '--worker'])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.SubprocessError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
