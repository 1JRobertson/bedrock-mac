#!/usr/bin/env python3
"""Assemble a local test app with prebuilt open-source components; never bundle a game/account."""
import hashlib
import importlib.util
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


MACHO_MAGICS = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',
                b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf', b'\xbe\xba\xfe\xca', b'\xbf\xba\xfe\xca'}


SOURCE_FILES = (
    'launcher/setup.py', 'launcher/BedrockLauncher.swift', 'launcher/Icon.swift',
    'package-launcher.py', 'build-launcher.sh', 'build-dmg.py', 'packaging-requirements.txt',
    'standalone.py', 'standalone-setup.py', 'standalone-gameinput.py', 'winrt.reg',
    'standalone-pickers.py', 'file-pickers/pickers.c', 'file-pickers/ids.h',
    'file-pickers/pickers.spec', 'file-pickers/build.sh', 'file-pickers/README.md',
    'file-pickers/check-windows.cmd', 'tests/file-picker-contract.c',
    'patches/standalone-dxmt-memory-lifetime.patch', 'standalone-dxmt-display-trace.c',
    'LICENSE', 'THIRD_PARTY.md',
    'release-runtime-profile.json', 'native-dependencies.lock.json',
)


def snapshot_sources(destination):
    """Compile, copy and hash the same captured bytes, even if the checkout changes."""
    destination.mkdir()
    for name in SOURCE_FILES:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / name).read_bytes())
    (destination / 'build-launcher.sh').chmod(0o755)
    shutil.copytree(ROOT / 'LICENSES', destination / 'LICENSES', symlinks=True)
    verify_bundle_links(destination)
    return {str(path.relative_to(destination)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(destination.rglob('*')) if path.is_file() and not path.is_symlink()}


def native_inventory(resources):
    """Record load-command requirements; the SDK version is not the minimum OS."""
    inventory = {}
    for path in sorted(resources.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as file:
            if file.read(4) not in MACHO_MAGICS:
                continue
        commands = subprocess.check_output(['otool', '-l', str(path)], text=True)
        versions = re.findall(r'\bminos\s+([0-9.]+)', commands)
        versions += re.findall(r'LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)', commands)
        if not versions:
            raise RuntimeError('Native component has no macOS deployment target: ' + str(path))
        inventory[str(path.relative_to(resources))] = sorted(set(versions))
    return inventory


def minimum_macos(resources):
    """Every native component must run on the advertised macOS version."""
    return inventory_minimum(native_inventory(resources))


def inventory_minimum(inventory):
    versions = {'15.0'}
    versions.update(version for values in inventory.values() for version in values)
    return max(versions, key=lambda value: tuple(map(int, value.split('.'))))


def validate_release_runtime(wine, dxmt, source=None):
    """A release package must not silently absorb an experimental live runtime."""
    source = source or ROOT
    spec = importlib.util.spec_from_file_location('packaged_pickers', source / 'standalone-pickers.py')
    pickers = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pickers)
    pickers.verify_runtime(wine, source)
    manifests = []
    for path, allowed in ((wine / 'build-manifest.json', {'heap_reuse'}),
                          (dxmt / 'manifest.json', {'shared_buffers', 'packed_constants', 'input_layout_reuse'})):
        metadata = json.loads(path.read_text())
        modifications = metadata.get('local_modifications', {})
        if not isinstance(modifications, dict) or set(modifications) - allowed:
            found = ', '.join(sorted(set(modifications) - allowed)) if isinstance(modifications, dict) else 'invalid metadata'
            raise RuntimeError('Release packaging excludes experimental profiles: ' + found)
        manifests.append(metadata)
    for name in ('bedrock-refmove.json', 'bedrock-frame-slab.json', 'metrics-hud.json',
                 'frame-pacing.json', 'pending-hud.json', 'dxmt-borrowed-constants.json',
                 'dxmt-pool-adapter.json'):
        if (wine / name).exists() or (wine / name).is_symlink():
            raise RuntimeError('Use a reviewed release runtime without ' + name)
    profile = json.loads((source / 'release-runtime-profile.json').read_text())
    wine_metadata, graphics = manifests
    if (wine_metadata.get('wine_source_revision') != profile['upstream']['winegdk']['commit']
            or wine_metadata.get('architecture') != 'x86_64'
            or graphics.get('source_commit') != profile['upstream']['dxmt']['commit']):
        raise RuntimeError('Runtime provenance differs from the selected release profile')
    files = graphics.get('files', {})
    required = {'x86_64-windows/' + name + '.dll' for name in ('d3d11', 'dxgi', 'd3d10core', 'winemetal')}
    required.add('x86_64-unix/winemetal.so')
    if set(files) != required:
        raise RuntimeError('DXMT manifest does not describe the complete release payload')
    for name, expected in files.items():
        verify_runtime_file(dxmt, name, expected)
        # A validated Unix bridge deliberately replaces Wine's upstream copy.
        if name != 'x86_64-unix/winemetal.so' or not (wine / 'dxmt-unix-bridge.json').is_file():
            verify_runtime_file(wine, 'lib/wine/' + name, expected)
    heap = wine_metadata.get('local_modifications', {}).get('heap_reuse')
    if heap is not None:
        verify_runtime_file(wine, 'lib/wine/x86_64-windows/ntdll.dll', heap.get('dll_sha256'))
    receipt = json.loads((wine / 'native-dependency-manifest.json').read_text())
    if (receipt.get('source_built') is not True or receipt.get('architecture') != 'x86_64'
            or receipt.get('lock_sha256') != hashlib.sha256((source / 'native-dependencies.lock.json').read_bytes()).hexdigest()
            or receipt.get('source_archives') != json.loads((source / 'native-dependencies.lock.json').read_text())['components']
            or receipt != wine_metadata.get('native_dependency_manifest')):
        raise RuntimeError('Native dependency provenance differs from the reviewed source build')
    native_files = {name: record for name, record in receipt.get('files', {}).items()
                    if name.startswith('lib/') and len(Path(name).parts) == 2 and name.endswith('.dylib')}
    actual = {'lib/' + path.name for path in (wine / 'lib').glob('*.dylib')}
    if (set(native_files) != actual
            or not {'lib/libgnutls.30.dylib', 'lib/libfreetype.6.dylib'}.issubset(native_files)):
        raise RuntimeError('Native dependency library closure differs from its receipt')
    for name, record in native_files.items():
        if 'symlink' in record:
            path = wine / name
            if not path.is_symlink() or str(path.readlink()) != record['symlink']:
                raise RuntimeError('Native dependency link differs from its receipt: ' + name)
            target = path.resolve()
            if not target.is_relative_to(wine.resolve()) or str(target.relative_to(wine.resolve())) not in native_files:
                raise RuntimeError('Native dependency link target is unrecorded: ' + name)
        else:
            verify_runtime_file(wine, name, record.get('sha256'))


def verify_runtime_file(root, name, expected):
    path = root / name
    if (not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected)
            or path.is_symlink() or not path.is_file()
            or not path.resolve().is_relative_to(root.resolve())
            or hashlib.sha256(path.read_bytes()).hexdigest() != expected):
        raise RuntimeError('Runtime bytes differ from their manifest: ' + name)


def verify_bundle_links(resources):
    """Do not ship symlinks into the build machine or missing dependencies."""
    root = resources.resolve()
    for path in resources.rglob('*'):
        if path.is_symlink():
            target = path.resolve()
            if not target.is_relative_to(root) or not target.exists():
                raise RuntimeError('Bundle symlink escapes resources or is broken: ' + str(path))


def verify_payload_content(resources):
    """Reject common game, account, world and private-key payloads at assembly."""
    forbidden = {'minecraft.windows.exe', 'account-v1', 'helper-session.json',
                 'level.dat', 'levelname.txt', 'onboarding.log', 'tokens.json',
                 'credentials.json', '.ds_store'}
    for path in resources.rglob('*'):
        if path.name.lower() in forbidden or path.suffix.lower() in {'.pfx', '.p12', '.key', '.pdb'}:
            raise RuntimeError('Private or unapproved payload in app: ' + str(path.relative_to(resources)))


def verify_source_bridge(wine, dxmt, source=None):
    source = source or ROOT
    if not (wine / 'dxmt-unix-bridge.json').exists():
        return None
    spec = importlib.util.spec_from_file_location('packaged_runtime', source / 'standalone.py')
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    runtime.ROOT, runtime.WINE, runtime.DXMT = source, wine, dxmt
    runtime.verify_unix_bridge()
    return json.loads((wine / 'dxmt-unix-bridge.json').read_text())


def record_packaged_bridge(resources, original):
    if original is None:
        return
    wine = resources / 'runtime/wine'
    metadata = dict(original)
    # Ad-hoc signing changes Mach-O bytes. Retain build provenance and record
    # the exact signed copies, including the separately signed upstream reference.
    metadata['source_files'] = original['files']
    metadata['files'] = {name: hashlib.sha256((wine / 'lib/wine/x86_64-unix' / name).read_bytes()).hexdigest()
                         for name in original['files']}
    metadata['packaged_upstream_sha256'] = hashlib.sha256(
        (resources / 'runtime/dxmt/x86_64-unix/winemetal.so').read_bytes()).hexdigest()
    (wine / 'dxmt-unix-bridge.json').write_text(json.dumps(metadata, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=APP)
    parser.add_argument('--wine', type=Path, default=ROOT / 'runtime/standalone/wine')
    parser.add_argument('--dxmt', type=Path, default=ROOT / 'runtime/standalone/dxmt')
    parser.add_argument('--helper', type=Path, default=ROOT / 'sources/xodus/target/release/examples/standalone_helper')
    parser.add_argument('--pyinstaller', type=Path, default=ROOT / 'build/packaging-env/bin/pyinstaller')
    parser.add_argument('--work-dir', type=Path, help='New, isolated build directory (default: beside output)')
    parser.add_argument('--version', default='0.3.0')
    parser.add_argument('--build-number', default='3')
    parser.add_argument('--notices', action='append', default=[], metavar='LABEL=DIRECTORY',
                        help='Snapshot generated dependency notices into LICENSES/LABEL')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or not re.fullmatch(r'\d+', args.build_number):
        parser.error('Use a numeric x.y.z version and numeric build number.')
    app = args.output.absolute()
    work = (args.work_dir or app.parent / (app.stem + '-build')).absolute()
    wine, dxmt, helper = args.wine.resolve(), args.dxmt.resolve(), args.helper.resolve()
    required = [wine / 'build-manifest.json', wine / 'bin/wine', wine / 'bin/wineserver',
                dxmt / 'manifest.json', helper, args.pyinstaller.absolute()]
    for path in required:
        if not path.is_file():
            raise SystemExit('Complete the developer build first. Missing: ' + str(path))
    if app.exists() or app.is_symlink():
        raise SystemExit('The packaged app already exists. Move it aside before making a new package.')
    if work.exists() or work.is_symlink():
        raise SystemExit('Build directory already exists. Choose a new --work-dir.')
    if work == app or work in app.parents or app in work.parents:
        raise SystemExit('App and build directories must not contain one another.')
    validate_release_runtime(wine, dxmt)
    work.mkdir(parents=True)
    captured = work / "source"
    source_hashes = snapshot_sources(captured)
    notice_hashes = {}
    for item in args.notices:
        label, separator, directory = item.partition('=')
        if not separator or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', label):
            parser.error('--notices must be LABEL=DIRECTORY with a simple folder label')
        destination = captured / 'LICENSES' / label
        shutil.copytree(Path(directory).resolve(), destination, symlinks=True)
        verify_bundle_links(captured)
        notice_hashes.update({str(path.relative_to(captured)): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in sorted(destination.rglob('*')) if path.is_file() and not path.is_symlink()})
    bridge = verify_source_bridge(wine, dxmt, captured)
    launcher = work / 'Bedrock for Mac.app'
    subprocess.run([str(captured / 'build-launcher.sh'), '--output', str(launcher),
                    '--work-dir', str(work), '--version', args.version,
                    '--build-number', args.build_number], check=True)
    subprocess.run([str(required[-1]), '--noconfirm', '--clean', '--onedir',
                    '--hidden-import', 'ctypes', '--hidden-import', 'socket',
                    '--name', 'BedrockWorker', '--distpath', str(work / 'frozen'),
                    '--workpath', str(work / 'pyinstaller'), '--specpath', str(work),
                    str(captured / 'launcher/setup.py')], check=True)
    app.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(launcher, app)
    resources = app / 'Contents/Resources'
    resources.mkdir(exist_ok=True)
    shutil.copytree(work / 'frozen/BedrockWorker', resources / 'worker', symlinks=True)
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
    for name in ('native-dependency-manifest.json', 'file-pickers-build.json', 'notices'):
        source = wine / name
        if source.is_dir():
            shutil.copytree(source, packaged_wine / name, symlinks=True)
        elif source.is_file():
            shutil.copy2(source, packaged_wine / name)
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
    for name in ('standalone.py', 'standalone-setup.py', 'standalone-gameinput.py', 'standalone-pickers.py', 'winrt.reg',
                 'file-pickers/pickers.c', 'file-pickers/ids.h', 'file-pickers/pickers.spec',
                 'file-pickers/build.sh', 'file-pickers/README.md', 'file-pickers/check-windows.cmd',
                 'tests/file-picker-contract.c'):
        target = resources / 'scripts' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(captured / name, target)
    if bridge is not None:
        for name in ('patches/standalone-dxmt-memory-lifetime.patch', 'standalone-dxmt-display-trace.c'):
            target = resources / 'scripts' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(captured / name, target)
    shutil.copytree(captured / 'LICENSES', resources / 'LICENSES', symlinks=True)
    for name in ('LICENSE', 'THIRD_PARTY.md'):
        shutil.copy2(captured / name, resources / name)
    if bridge is not None:
        # Validate the copies before signing, not just mutable input paths.
        (packaged_wine / 'dxmt-unix-bridge.json').write_text(json.dumps(bridge, indent=2) + '\n')
        verify_source_bridge(packaged_wine, resources / 'runtime/dxmt', captured)
    verify_bundle_links(resources)
    verify_payload_content(resources)
    validate_release_runtime(packaged_wine, resources / 'runtime/dxmt', captured)
    links = {str(path.relative_to(resources)): os.readlink(path)
             for path in sorted(resources.rglob("*")) if path.is_symlink()}
    (resources / "payload-symlinks.json").write_text(json.dumps(links, indent=2) + "\n")
    native = native_inventory(app / 'Contents')
    (resources / 'native-minimums.json').write_text(json.dumps(native, indent=2) + '\n')
    provenance = {
        'version': args.version, 'build_number': args.build_number,
        'signing': 'ad-hoc; local test only; not notarized',
        'source_sha256': source_hashes,
        'notice_sha256': notice_hashes,
        'helper_input_sha256': hashlib.sha256((resources / 'standalone_helper').read_bytes()).hexdigest(),
        'wine_manifest_sha256': hashlib.sha256((packaged_wine / 'build-manifest.json').read_bytes()).hexdigest(),
        'dxmt_manifest_sha256': hashlib.sha256((resources / 'runtime/dxmt/manifest.json').read_bytes()).hexdigest(),
        'pyinstaller_version': subprocess.check_output([str(required[-1]), '--version'], text=True).strip(),
        'macos_minimum': inventory_minimum(native),
    }
    (resources / 'build-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    # Sign nested binaries before hashing: signing modifies their bytes.
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    record_packaged_bridge(resources, bridge)
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
    plist['LSMinimumSystemVersion'] = inventory_minimum(native)
    with info.open('wb') as file:
        plistlib.dump(plist, file)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('Minimum macOS:', plist['LSMinimumSystemVersion'])
    print(app)


if __name__ == '__main__':
    main()
