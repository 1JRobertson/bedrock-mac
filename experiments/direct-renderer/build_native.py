#!/usr/bin/env python3
"""Build the research Metal worker only; never install or launch it."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).resolve().parent / 'native-source'
    recipe = json.loads((source / 'native-build.json').read_text())
    platform = ['-arch', recipe['architecture'],
                '-mmacosx-version-min=' + recipe['minimum_macos']]
    objects = []
    for mode in ('arc', 'c'):
        for name in recipe[mode]:
            obj = output / (Path(name).stem + '.o')
            flags = (['-std=gnu2x', '-fobjc-arc', '-fobjc-arc-exceptions', '-fblocks']
                     if mode == 'arc' else ['-std=c11'])
            subprocess.run(['/usr/bin/clang', *platform, *flags, '-O2',
                            '-Wall', '-Wextra', '-Werror', '-c', str(source / name),
                            '-o', str(obj)], check=True)
            objects.append(str(obj))
    binary = output / 'native-draw-executor'
    frameworks = [v for name in recipe['frameworks'] for v in ('-framework', name)]
    subprocess.run(['/usr/bin/clang', *platform, '-std=gnu2x', '-fno-objc-arc',
                    '-O2', '-Wall', '-Wextra', '-Werror',
                    *(str(source / name) for name in recipe['manual']),
                    *objects, *frameworks, '-o', str(binary)], check=True)
    print(json.dumps({'binary': str(binary),
                      'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}))


if __name__ == '__main__':
    main()
