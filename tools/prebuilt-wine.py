#!/usr/bin/env python3
"""Pack or install Wine and the graphics probes for a matching source setup."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import runpy
import shutil
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path('runtime/standalone')
WINE_DIRS = ('bin', 'lib', 'notices', 'share/wine')
WINE_RECEIPTS = ('build-manifest.json', 'native-dependency-manifest.json', 'file-pickers-build.json')
PROBES = ('standalone-graphics-probe', 'standalone-graphics-shader-probe', 'runtime-auth-probe',
          'store-callback-probe', 'runtime-privilege-probe', 'xuser-claims-test')
OVERLAYS = ('x86_64-windows/d3d11.dll', 'x86_64-windows/dxgi.dll', 'x86_64-windows/d3d10core.dll',
            'x86_64-windows/winemetal.dll', 'x86_64-unix/winemetal.so')
RECEIPT = 'prebuilt-wine-source.json'


def digest(path):
    hash_value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hash_value.update(chunk)
    return hash_value.hexdigest()


def source_inputs(root):
    names = ['config/native-dependencies.lock.json', 'config/release-runtime-profile.json',
             'tools/bootstrap-sources.py', 'tools/build-native-dependencies.py',
             'tools/build-standalone-wine.sh', 'tools/verify-wine-source.py',
             'tools/build-standalone-probes.sh', 'client/standalone-pickers.py',
             'tests/xuser-claims.c']
    names.extend(f'native/probes/{name}.c' for name in PROBES if name != 'xuser-claims-test')
    names.extend(f'patches/{name}' for name in wine_patches(root))
    names.extend(runpy.run_path(str(root / 'client/standalone-pickers.py'))['SOURCE_INPUTS'])
    return {name: digest(root / name) for name in sorted(set(names))}


def wine_patches(root):
    projects = runpy.run_path(str(root / 'tools/bootstrap-sources.py'))['PROJECTS']
    return [*projects['winegdk']['patches'], *sorted(path.name for path in (root / 'patches').glob('standalone-wine-*.patch'))]


def review_bundle(stage, root):
    receipt = json.loads((stage / RECEIPT).read_text())
    if receipt != {'schema': 1, 'source_sha256': source_inputs(root)}:
        raise ValueError('The prebuilt tools were made for different source files.')
    wine = stage / 'wine'
    provenance = json.loads((wine / 'build-manifest.json').read_text())
    profile = json.loads((root / 'config/release-runtime-profile.json').read_text())
    deps = json.loads((wine / 'native-dependency-manifest.json').read_text())
    if (provenance.get('architecture') != 'x86_64' or provenance.get('local_modifications')
            or provenance.get('wine_source_revision') != profile['upstream']['winegdk']['commit']
            or deps != provenance.get('native_dependency_manifest') or deps.get('source_built') is not True
            or deps.get('lock_sha256') != receipt['source_sha256']['config/native-dependencies.lock.json']):
        raise ValueError('The archive differs from the supported Wine build or dependency lock.')
    verification = provenance['source_verification']
    for field, name in (('bootstrap_sha256', 'tools/bootstrap-sources.py'),
                        ('verifier_sha256', 'tools/verify-wine-source.py')):
        if verification.get(field) != receipt['source_sha256'][name]:
            raise ValueError('The Wine source verification receipt differs from this checkout.')
    if verification.get('patches') != {name: receipt['source_sha256'][f'patches/{name}'] for name in wine_patches(root)}:
        raise ValueError('The Wine patches in the archive differ from this checkout.')
    runpy.run_path(str(root / 'client/standalone-pickers.py'))['verify_runtime'](wine, root)
    for relative in ('bin/wine', 'bin/wineserver', 'lib/wine/x86_64-unix/ntdll.so',
                     'lib/wine/x86_64-windows/bedrock-pickers.dll'):
        if not (wine / relative).is_file():
            raise ValueError(f'Missing Wine file: {relative}')
    if not all((stage / 'probes' / f'{name}.exe').is_file() for name in PROBES):
        raise ValueError('Missing the prebuilt graphics or runtime probes.')


def allowed_entry(name):
    if name in (RECEIPT, 'wine', 'wine/share', 'probes') or name in {f'probes/{probe}.exe' for probe in PROBES}:
        return True
    return name in {f'wine/{receipt}' for receipt in WINE_RECEIPTS} or any(
        name == f'wine/{directory}' or name.startswith(f'wine/{directory}/') for directory in WINE_DIRS)


def archive_entries(package):
    entries = {}
    expanded_bytes = 0
    for entry in package:
        name = entry.name
        parts = PurePosixPath(name).parts
        if (name != '/'.join(parts) or '..' in parts or not allowed_entry(name) or name in entries
                or len(entries) >= 10000 or not (entry.isfile() or entry.isdir() or entry.issym())):
            raise ValueError('The archive contains an unexpected or duplicate entry.')
        if entry.issym():
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), entry.linkname))
            if not name.startswith('wine/') or not target.startswith('wine/') or not allowed_entry(target):
                raise ValueError('The archive contains a link outside the Wine tools.')
        expanded_bytes += entry.size
        if expanded_bytes > 1024**3:
            raise ValueError('The Wine archive expands beyond 1 GiB.')
        entries[name] = entry
    for name in entries:
        for parent in PurePosixPath(name).parents:
            if str(parent) in entries and not entries[str(parent)].isdir():
                raise ValueError('The archive places a file inside a link.')
    return list(entries.values())


def pack(root, built, archive):
    wine_source = built / RUNTIME / 'wine'
    dxmt = built / RUNTIME / 'dxmt'
    with tempfile.TemporaryDirectory(prefix='.prebuilt-wine-', dir=archive.parent) as staging:
        stage = Path(staging)
        wine = stage / 'wine'
        wine.mkdir()
        for name in WINE_DIRS:
            shutil.copytree(wine_source / name, wine / name, symlinks=True,
                            ignore=shutil.ignore_patterns('*.a', '*.o', '*.def', '*.debug', '.DS_Store'))
        for name in WINE_RECEIPTS:
            shutil.copyfile(wine_source / name, wine / name)
        overlay = json.loads((dxmt / 'manifest.json').read_text())['runtime_overlay']
        if set(overlay) != set(OVERLAYS):
            raise ValueError('The build does not have the recorded DXMT overlay.')
        for name in OVERLAYS:
            target = wine / 'lib/wine' / name
            backup = overlay[name].get('backup')
            if backup:
                prefix = f'wine-originals/{name}.'
                if not backup.startswith(prefix) or not re.fullmatch(r'[0-9a-f]{64}', backup[len(prefix):]):
                    raise ValueError('Unexpected Wine backup path.')
                source = dxmt / backup
                if source.is_symlink() or digest(source) != backup[len(prefix):]:
                    raise ValueError('The original Wine graphics file failed verification.')
                target.unlink()
                shutil.copyfile(source, target)
            else:
                target.unlink(missing_ok=True)
        (wine / 'lib/wine/x86_64-unix/winemetal-upstream.so').unlink(missing_ok=True)
        probes = stage / 'probes'
        probes.mkdir()
        for name in PROBES:
            shutil.copyfile(built / RUNTIME / 'probes' / f'{name}.exe', probes / f'{name}.exe')
        (stage / RECEIPT).write_text(json.dumps({'schema': 1, 'source_sha256': source_inputs(root)}) + '\n')
        review_bundle(stage, root)
        temporary = stage / 'archive.tar.gz'
        with tarfile.open(temporary, 'w:gz') as package:
            for name in ('wine', 'probes', RECEIPT):
                package.add(stage / name, arcname=name)
        with tarfile.open(temporary, 'r:gz') as package:
            archive_entries(package)
        os.link(temporary, archive)
    print(f'{digest(archive)}  {archive.name}')


def install(root, archive, expected):
    destination = root / RUNTIME
    for path in (root / 'runtime', destination):
        if path.is_symlink():
            raise ValueError('The runtime folders must not be symbolic links.')
    destination.mkdir(parents=True, exist_ok=True)
    names = ('wine', 'probes')
    if any(os.path.lexists(destination / name) for name in names):
        raise ValueError('Use a fresh setup folder. The existing Wine and probes were preserved.')
    if not archive.is_file() or archive.stat().st_size > 1024**3:
        raise ValueError('The prebuilt Wine download must be a file smaller than 1 GiB.')
    with tempfile.TemporaryDirectory(prefix='.prebuilt-wine-', dir=destination) as staging:
        stage = Path(staging)
        private_archive = stage / 'archive.tar.gz'
        shutil.copyfile(archive, private_archive)
        if digest(private_archive) != expected:
            raise ValueError('The prebuilt Wine download does not match its SHA-256.')
        with tarfile.open(private_archive, 'r:gz') as package:
            entries = archive_entries(package)
            package.extractall(stage, members=entries, filter='data')
        review_bundle(stage, root)
        installed = []
        try:
            for name in names:
                (destination / name).mkdir()
                installed.append(name)
                os.replace(stage / name, destination / name)
        except BaseException:
            for name in reversed(installed):
                if (stage / name).exists():
                    (destination / name).rmdir()
                else:
                    os.replace(destination / name, stage / name)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    create = commands.add_parser('pack')
    create.add_argument('archive', type=Path)
    create.add_argument('--built-root', type=Path, required=True)
    use = commands.add_parser('install')
    use.add_argument('archive', type=Path)
    use.add_argument('--sha256', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'pack':
            pack(ROOT, args.built_root.resolve(), args.archive.absolute())
        else:
            if not re.fullmatch(r'[a-fA-F0-9]{64}', args.sha256):
                raise ValueError('Provide the trusted 64-character archive SHA-256.')
            install(ROOT, args.archive, args.sha256.lower())
    except (OSError, ValueError, KeyError, RuntimeError, tarfile.TarError) as error:
        parser.exit(1, f'Prebuilt Wine: {error}\n')


if __name__ == '__main__':
    main()
