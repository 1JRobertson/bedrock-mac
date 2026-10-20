#!/usr/bin/env python3
"""Compare exact-current with locally extracted x64 allocator code, without Wine.

An explicit, exact-hash local game is required. Extracted instructions stay in
ignored build output and must never be exported. Only anonymous test memory is
patched; the executable is opened read-only and its entry point is never run.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('exact_builder', ROOT / 'standalone-bedrock-allocator.py')
exact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exact)
BASE_RVA = 0x52f5000
REGIONS = ((0x52f5c70, 1380), (0x52f6320, 215), (0x52f6a50, 378))


def patch_headers(path):
    files = {}
    for chunk in path.read_text().split('--- /dev/null\n')[1:]:
        lines = chunk.splitlines(keepends=True)
        name = lines[0].removeprefix('+++ b/').strip()
        files[name] = ''.join(line[1:] for line in lines[2:] if line.startswith('+')).encode()
    return files


def extract(raw):
    if exact.sha(raw) != exact.ref.GAME_SHA:
        raise RuntimeError('Requires exact Minecraft 1.26.5203.0 executable SHA256')
    nt = struct.unpack_from('<I', raw, 0x3c)[0]
    if raw[:2] != b'MZ' or raw[nt:nt + 4] != b'PE\0\0' or struct.unpack_from('<H', raw, nt + 4)[0] != 0x8664:
        raise RuntimeError('Expected x86-64 PE executable')
    opt = nt + 24
    if struct.unpack_from('<H', raw, opt)[0] != 0x20b:
        raise RuntimeError('Expected PE32+ executable')
    section_start = opt + struct.unpack_from('<H', raw, nt + 20)[0]
    sections = [struct.unpack_from('<8sIIIIIIHHI', raw, section_start + i * 40)
                for i in range(struct.unpack_from('<H', raw, nt + 6)[0])]
    code = bytearray(b'\xcc' * 8192)
    for rva, length in REGIONS:
        candidates = [s for s in sections if s[2] <= rva and rva + length <= s[2] + s[3]]
        if len(candidates) != 1:
            raise RuntimeError('Allocator RVA does not map to one complete raw section')
        section = candidates[0]
        offset = section[4] + rva - section[2]
        if offset + length > len(raw) or not section[9] & 0x20000000:
            raise RuntimeError('Allocator section is truncated or non-executable')
        code[rva - BASE_RVA:rva - BASE_RVA + length] = raw[offset:offset + length]
    return code


def with_refmove(code):
    result = bytearray(code)
    header = patch_headers(exact.ref.PATCH)['dlls/ntdll/manifest.h'].decode()
    edits = header.split('static const struct brm_edit brm_edits[] = {', 1)[1].split('};', 1)[0]
    matches = re.findall(r'\{(\d+)u,(\d+)u,\{([^}]+)\},\{([^}]+)\}\}', edits)
    if len(matches) != 6:
        raise RuntimeError('Unexpected pinned refmove edit manifest')
    for rva, size, before, after in matches:
        index, size = int(rva) - BASE_RVA, int(size)
        before = bytes(int(x, 0) for x in before.split(','))
        after = bytes(int(x, 0) for x in after.split(','))
        if len(before) != size or len(after) != size or result[index:index + size] != before:
            raise RuntimeError('Refmove instruction guard mismatch')
        result[index:index + size] = after
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/bedrock-exact-differential')
    parser.add_argument('--compiler', default='clang++')
    args = parser.parse_args()
    exact.check_patch()
    out = exact.ref.no_symlink_path(args.output)
    game = args.game.resolve(strict=True)
    if out == game.parent or game.parent in out.parents or out in game.parents:
        raise RuntimeError('Test output must be separate from the game directory')
    for name in ('current_reserve.h', 'allocator-original-x64.bin', 'allocator-refmove-x64.bin',
                 'differential', 'result.json'):
        exact.ref.safe_path(out, name)
    code = extract(game.read_bytes())
    code_refmove = with_refmove(code)
    compiler = shutil.which(args.compiler)
    if not compiler:
        raise RuntimeError('Missing C++ compiler: ' + args.compiler)
    if platform.system() != 'Darwin' and platform.machine() not in ('x86_64', 'AMD64'):
        raise RuntimeError('Requires x86-64 execution or Rosetta on macOS')
    out.mkdir(parents=True, exist_ok=True)
    header = patch_headers(exact.PATCH)['dlls/ntdll/current_reserve.h']
    exact.write(out / 'current_reserve.h', header)
    exact.write(out / 'allocator-original-x64.bin', code)
    exact.write(out / 'allocator-refmove-x64.bin', code_refmove)
    command = [compiler, '-std=c++17', '-O2', '-pthread', '-I', str(out)]
    if platform.system() == 'Darwin':
        command += ['-arch', 'x86_64']
    command += [str(ROOT / 'tests/bedrock-exact-differential.cpp'), '-o', str(out / 'differential')]
    subprocess.run(command, check=True)
    evidence = {'game_sha256': exact.ref.GAME_SHA, 'patch_sha256': exact.PATCH_SHA,
                'harness_sha256': exact.sha((ROOT / 'tests/bedrock-exact-differential.cpp').read_bytes()),
                'current_header_sha256': exact.sha(header), 'game_modified': False,
                'game_launched': False, 'variants': {}}
    for variant in ('original', 'refmove'):
        blob = out / ('allocator-' + variant + '-x64.bin')
        run = subprocess.run([str(out / 'differential'), str(blob)], capture_output=True, text=True,
                             check=True, timeout=60)
        result = json.loads(run.stdout)
        if result.get('passed') is not True:
            raise RuntimeError('Differential harness did not report success')
        evidence['variants'][variant] = dict(result, extracted_code_sha256=exact.sha(blob.read_bytes()))
    exact.write(out / 'result.json', exact.json_bytes(evidence))
    print(json.dumps(evidence, indent=2, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, struct.error, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
