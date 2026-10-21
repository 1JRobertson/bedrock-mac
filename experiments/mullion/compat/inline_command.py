#!/usr/bin/env python3
"""Inline only Mullion's quoted internal shader headers; preserve Metal includes."""
from pathlib import Path
import re

BASE = Path(__file__).resolve().parent
SOURCE = BASE.parent / 'source/src'
seen = set()

def inline(path):
    path = path.resolve()
    if not path.is_relative_to(SOURCE.resolve()):
        raise RuntimeError('Shader include escaped the pinned source tree')
    if path in seen:
        return ''
    seen.add(path)
    result = []
    for line in path.read_text().splitlines():
        match = re.fullmatch(r'\s*#include\s+"([^"]+)"\s*', line)
        if match:
            result.append(inline(path.parent / match[1]))
        elif line.strip() != '#pragma once':
            result.append(line)
    return '\n'.join(result) + '\n'

if __name__ == '__main__':
    (BASE / 'command-inlined.metal').write_text(inline(SOURCE / 'mullion/mullion_command.metal'))
    print('Inlined pinned Mullion internal command shader into compat/command-inlined.metal')
