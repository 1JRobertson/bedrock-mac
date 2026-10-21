#!/usr/bin/env python3
"""Package the existing local app in a drag-to-Applications disk image."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/packaged/Bedrock for Mac.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/Bedrock for Mac.dmg')
    args = parser.parse_args()
    app, output = args.app.resolve(), args.output.absolute()
    if not (app / 'Contents/Info.plist').is_file():
        parser.error('Build the packaged app first.')
    manifest = output.with_suffix(output.suffix + '.json')
    if output.exists() or output.is_symlink() or manifest.exists() or manifest.is_symlink():
        parser.error('Output already exists; choose a new --output path.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('BedrockProjectPath') or not (app / 'Contents/Resources/payload-sha256.json').is_file():
        parser.error('Use the self-contained packaged app, not the developer launcher.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='bedrock-dmg-', dir=output.parent) as temporary:
        stage = Path(temporary) / 'Install'
        stage.mkdir()
        # Only the packaged app is included, never its surrounding build tree.
        staged_app = stage / app.name
        shutil.copytree(app, staged_app, symlinks=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged_app)], check=True)
        info = plistlib.loads((staged_app / 'Contents/Info.plist').read_bytes())
        inventory_sha256 = file_sha256(staged_app / 'Contents/Resources/payload-sha256.json')
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        image = Path(temporary) / 'Bedrock for Mac.dmg'
        subprocess.run(['hdiutil', 'create', '-srcfolder', str(stage), '-volname',
                        'Bedrock for Mac', '-format', 'UDZO', str(image)], check=True)
        subprocess.run(['hdiutil', 'verify', str(image)], check=True)
        image_sha256 = file_sha256(image)
        image_bytes = image.stat().st_size
        # Stage on the destination filesystem, then publish without replacing a
        # file created since the initial check. Failed builds leave no final DMG.
        os.link(image, output)
    with manifest.open('x') as receipt:
        receipt.write(json.dumps({
            'filename': output.name,
            'sha256': image_sha256,
            'bytes': image_bytes,
            'version': info['CFBundleShortVersionString'],
            'build_number': info['CFBundleVersion'],
            'minimum_macos': info['LSMinimumSystemVersion'],
            'payload_inventory_sha256': inventory_sha256,
            'distribution': 'Local test image; signing/notarization and fresh-machine validation are separate gates.',
        }, indent=2) + '\n')
    print(output)
    print('Local test image. Developer ID signing and notarization are separate release steps.')


if __name__ == '__main__':
    main()
