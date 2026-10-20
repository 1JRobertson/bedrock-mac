#!/usr/bin/env python3
"""Package the existing local app in a drag-to-Applications disk image."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


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
        shutil.copytree(app, stage / app.name, symlinks=True)
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        subprocess.run(['hdiutil', 'create', '-srcfolder', str(stage), '-volname',
                        'Bedrock for Mac', '-format', 'UDZO', '-ov', str(output)], check=True)
    subprocess.run(['hdiutil', 'verify', str(output)], check=True)
    manifest.write_text(json.dumps({
        'filename': output.name,
        'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
        'bytes': output.stat().st_size,
        'version': info['CFBundleShortVersionString'],
        'build_number': info['CFBundleVersion'],
        'minimum_macos': info['LSMinimumSystemVersion'],
        'payload_inventory_sha256': hashlib.sha256((app / 'Contents/Resources/payload-sha256.json').read_bytes()).hexdigest(),
        'distribution': 'Local test image; signing/notarization and fresh-machine validation are separate gates.',
    }, indent=2) + '\n')
    print(output)
    print('Local test image. Developer ID signing and notarization are separate release steps.')


if __name__ == '__main__':
    main()
