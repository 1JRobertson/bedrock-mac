#!/usr/bin/env python3
"""Package the existing local app in a drag-to-Applications disk image."""
import argparse
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
    if output.exists() or output.is_symlink():
        parser.error('Output already exists; choose a new --output path.')
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
    print(output)
    print('Local test image. Developer ID signing and notarization are separate release steps.')


if __name__ == '__main__':
    main()
