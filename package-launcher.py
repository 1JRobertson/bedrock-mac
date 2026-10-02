#!/usr/bin/env python3
"""Assemble a local test app with prebuilt open-source components; never bundle a game/account."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
APP = ROOT / 'build/packaged/Bedrock for Mac.app'


MACHO_MAGICS = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}


def minimum_macos(resources):
    """Every native component must run on the advertised macOS version."""
    versions = {'15.0'}
    for path in resources.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as file:
            if file.read(4) not in MACHO_MAGICS:
                continue
        commands = subprocess.check_output(['otool', '-l', str(path)], text=True)
        versions.update(re.findall(r'\bminos\s+([0-9.]+)', commands))
        versions.update(re.findall(r'LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)', commands))
    return max(versions, key=lambda value: tuple(map(int, value.split('.'))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=APP)
    args = parser.parse_args()
    app = args.output.absolute()
    wine = ROOT / 'runtime/standalone/wine'
    dxmt = ROOT / 'runtime/standalone/dxmt'
    helper = ROOT / 'sources/xodus/target/release/examples/standalone_helper'
    required = [wine / 'build-manifest.json', wine / 'bin/wine', wine / 'bin/wineserver',
                dxmt / 'manifest.json', helper, ROOT / 'build/packaging-env/bin/pyinstaller']
    for path in required:
        if not path.is_file():
            raise SystemExit('Complete the developer build first. Missing: ' + str(path))
    if app.exists() or app.is_symlink():
        raise SystemExit('The packaged app already exists. Move it aside before making a new package.')
    subprocess.run([str(ROOT / 'build-launcher.sh')], check=True)
    subprocess.run([str(required[-1]), '--noconfirm', '--clean', '--onedir',
                    '--name', 'BedrockWorker', '--distpath', str(ROOT / 'build/frozen'),
                    '--workpath', str(ROOT / 'build/pyinstaller'), '--specpath', str(ROOT / 'build'),
                    str(ROOT / 'launcher/setup.py')], check=True)
    app.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'build/Bedrock for Mac.app', app)
    resources = app / 'Contents/Resources'
    resources.mkdir(exist_ok=True)
    shutil.copytree(ROOT / 'build/frozen/BedrockWorker', resources / 'worker', symlinks=True)
    packaged_wine = resources / 'runtime/wine'
    (packaged_wine / 'bin').mkdir(parents=True)
    for name in ('wine', 'wine64', 'wineserver', 'wine-preloader', 'wine64-preloader'):
        source = wine / 'bin' / name
        if source.exists():
            shutil.copy2(source, packaged_wine / 'bin' / name, follow_symlinks=False)
    shutil.copytree(wine / 'lib', packaged_wine / 'lib', symlinks=True,
                    ignore=shutil.ignore_patterns('*.a', '*.o', '*.def', '*.debug'))
    shutil.copytree(wine / 'share/wine', packaged_wine / 'share/wine', symlinks=True)
    shutil.copy2(wine / 'build-manifest.json', packaged_wine / 'build-manifest.json')
    # Copy only the required DXMT payload and provenance; omit old Wine backups.
    for name in ('manifest.json', 'x86_64-windows', 'x86_64-unix', 'licenses'):
        source, target = dxmt / name, resources / 'runtime/dxmt' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target, symlinks=True)
        else:
            shutil.copy2(source, target)
    shutil.copy2(helper, resources / 'standalone_helper')
    (resources / 'scripts').mkdir()
    for name in ('standalone.py', 'standalone-setup.py', 'standalone-gameinput.py', 'winrt.reg'):
        shutil.copy2(ROOT / name, resources / 'scripts' / name)
    shutil.copytree(ROOT / 'LICENSES', resources / 'LICENSES')
    for name in ('LICENSE', 'THIRD_PARTY.md'):
        shutil.copy2(ROOT / name, resources / name)
    # Sign nested binaries before hashing: signing modifies their bytes.
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    # A local test artifact, not a public release: retain an exact payload inventory.
    inventory = {}
    for path in resources.rglob('*'):
        if path.is_file() and not path.is_symlink():
            inventory[str(path.relative_to(resources))] = hashlib.sha256(path.read_bytes()).hexdigest()
    (resources / 'payload-sha256.json').write_text(json.dumps(inventory, indent=2) + '\n')
    info = app / 'Contents/Info.plist'
    with info.open('rb') as file:
        plist = plistlib.load(file)
    plist.pop('BedrockProjectPath', None)
    plist['LSMinimumSystemVersion'] = minimum_macos(app / 'Contents')
    with info.open('wb') as file:
        plistlib.dump(plist, file)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('Minimum macOS:', plist['LSMinimumSystemVersion'])
    print(app)


if __name__ == '__main__':
    main()
