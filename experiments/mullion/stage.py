#!/usr/bin/env python3
"""Stage small pinned downloads and an independent APFS Wine clone; no game launch."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import urllib.request
import zipfile

BASE = Path(__file__).resolve().parent
CLIENT = Path(os.environ.get('MULLION_CLIENT_ROOT', BASE.parents[1])).resolve()
CLIENT_SCRIPTS = CLIENT / 'client' if (CLIENT / 'client/standalone.py').is_file() else CLIENT
TAG = 'v0.3'
SOURCE_COMMIT = '5dda0b9af63dd246003a9ee9f84fd738b81867f9'
SHA = 'c7f97f29cd9bcb5e2aaf776ffa9e84adfe566399e91fccd78c089e1ea27bdfe9'
DXC_SHA = 'ad31b1fc8443175d204f77a611fdb3ef2ec42759bdc2f1167368de24a4a7e7f1'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def download(url, path, limit):
    if path.exists():
        return
    temporary = path.with_suffix('.partial')
    size = 0
    with urllib.request.urlopen(url, timeout=60) as response, temporary.open('wb') as output:
        while chunk := response.read(1024 * 1024):
            size += len(chunk)
            if size > limit:
                raise RuntimeError('Download exceeds reviewed size bound.')
            output.write(chunk)
    temporary.rename(path)


def main():
    for path in (BASE, *BASE.parents):
        if path.is_symlink():
            raise RuntimeError('Experiment must not contain linked parent directories.')
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
            (BASE / 'dxc' / name).write_bytes(package.read('bin\\x64\\' + name))
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
    (BASE / 'versions.json').write_text(json.dumps(record, indent=2) + '\n')
    print('Mullion staged in experimental Wine; production runtime and bottle untouched.')


if __name__ == '__main__':
    main()
