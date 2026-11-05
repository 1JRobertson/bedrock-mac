#!/usr/bin/env python3
"""Launch one renderer via the normal license flow in a disposable checkout data root."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from benchmark import renderer_environment, stop, token, verify_build
from build_renderer import HERE, run, sha, UPSTREAM_DXGI_SHA

ROOT = HERE.parents[1]


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--home', type=Path, required=True,
                   help='Fresh, separately provisioned standalone data root under build/')
    p.add_argument('--renderer', type=Path, required=True)
    p.add_argument('--market', default='CA')
    p.add_argument('--seconds', type=int, default=240)
    a = p.parse_args()
    home = a.home.absolute()
    build = a.renderer.resolve()
    scratch = ROOT / 'build'
    if (not 30 <= a.seconds <= 600 or home.resolve() != home or
            not home.is_relative_to(scratch) or home == scratch or
            any(os.path.lexists(home / name) for name in
                ('bottles', 'renderer-run', '.minecraft-update',
                 'runtime/standalone/helper-session.json'))):
        p.error('Use a new data root under build/ with no prefix or prior session')
    mode = json.loads((build / 'renderer.json').read_text())['mode']
    if mode not in ('direct', 'control'):
        p.error('Unknown renderer mode')
    verify_build(build, mode)
    wine = home / 'runtime/standalone/wine'
    dxmt = home / 'runtime/standalone/dxmt'
    for name in ('game', 'runtime', 'runtime/standalone', 'runtime/standalone/wine',
                 'runtime/standalone/dxmt', 'sources', 'sources/xodus'):
        folder = home / name
        if not folder.is_dir() or folder.resolve() != folder:
            p.error('Missing or linked disposable directory: ' + name)
    required = ('game/Minecraft.Windows.exe', 'game/MicrosoftGame.Config',
                'game/.xodus-streaming.msixvc', 'game/Installers/GameInputRedist.msi',
                'runtime/xgameruntime.dll.threading',
                'sources/xodus/target/release/examples/standalone_helper')
    if any(not (home / name).is_file() or (home / name).resolve() != home / name
           for name in required):
        p.error('Provision the game, runtime and standalone helper first')
    if sha(wine / 'lib/wine/x86_64-windows/dxgi.dll') != UPSTREAM_DXGI_SHA:
        p.error('Wine needs the original DXMT 0.80 DXGI module')
    base = {k: v for k, v in os.environ.items()
            if not k.startswith(('BEDROCK_', 'DXMT_', 'WINE', 'DYLD_'))}
    # Refuse any mapped graphics files before writing to the explicit test home.
    modules = (('x86_64-unix', 'winemetal.so'), ('x86_64-unix', 'winemetal-upstream.so'),
               ('x86_64-windows', 'd3d11.dll'), ('x86_64-windows', 'winemetal.dll'))
    targets = [(parent / folder / name, build / name)
               for parent in (wine / 'lib/wine', dxmt) for folder, name in modules]
    for target, _ in targets:
        if target.resolve() != target or not target.parent.is_dir():
            p.error('Linked or missing runtime directory')
    existing = [str(target) for target, _ in targets if target.exists()]
    mapped = subprocess.run(['/usr/sbin/lsof', '-Fp', '--', *existing],
                            capture_output=True, text=True, timeout=15)
    if mapped.returncode not in (0, 1) or mapped.stdout.strip() or mapped.stderr.strip():
        p.error('Cannot establish that the disposable runtime is idle')

    frame = home / 'renderer-run'
    frame.mkdir(mode=0o700)
    for dest, src in targets:
        temporary = dest.with_name('.research-' + dest.name)
        with temporary.open('xb') as stream, src.open('rb') as source:
            shutil.copyfileobj(source, stream)
        temporary.replace(dest)
    native = build / 'worker/native-draw-executor'
    for flag, name in (('--initialize-chunk-stream', 'chunk-stream.bin'),
                       ('--initialize-readback-stream', 'readback-stream.bin'),
                       ('--initialize-shared-snapshots', 'shared-snapshots.bin')):
        run(native, flag, frame / name, env=base, timeout=15)
    common, source_env = renderer_environment(base, frame, mode)
    common['BEDROCK_NATIVE_SNAPSHOT_ARENA'] = str(frame / 'shared-snapshots.bin')
    source_env.update(BEDROCK_NATIVE_SNAPSHOT_ARENA=common['BEDROCK_NATIVE_SNAPSHOT_ARENA'],
                      BEDROCK_HOME=str(home))
    common.update(BEDROCK_FULLFRAME_DRAW_PRESENT_SECONDS=str(a.seconds),
                  BEDROCK_NATIVE_PRESENT_TRACE='1', BEDROCK_NATIVE_PRESENT_SAMPLES='1')
    token(frame / 'frame.arm')
    worker = launcher = None
    try:
        with (frame / 'worker.log').open('wb') as log:
            worker = subprocess.Popen([native, '--directory', frame, '--timeout', str(a.seconds)],
                                      env=common, cwd=frame, stdout=log, stderr=subprocess.STDOUT)
            launcher = subprocess.Popen([sys.executable, ROOT / 'client/standalone.py',
                                         'launch', '--market', a.market], env=source_env, cwd=ROOT)
            return launcher.wait()
    finally:
        stop(launcher)
        if worker is not None and worker.poll() is None:
            (frame / 'presentation.stop').write_bytes(b'stop\n')
            try:
                worker.wait(timeout=10)
            finally:
                stop(worker)


if __name__ == '__main__':
    sys.exit(main())
