#!/usr/bin/env python3
"""Guarded, isolated Mullion experiment. Never launches the normal bottle."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent
CLIENT = Path(os.environ.get('MULLION_CLIENT_ROOT', BASE.parents[1])).resolve()
CLIENT_SCRIPTS = CLIENT / 'client' if (CLIENT / 'client/standalone.py').is_file() else CLIENT
# Reuse a surrounding workspace guard when present; otherwise use this repo's.
GUARD = next((p / 'tools/qa_resource_guard.py' for p in reversed((BASE.parents[1], *BASE.parents[1].parents))
              if (p / 'tools/qa_resource_guard.py').is_file()), BASE.parents[1] / 'tools/qa_resource_guard.py')
WINE = BASE / 'wine'
PREFIX = BASE / 'prefix'
GAME = BASE / 'game'
LOGS = BASE / 'logs'
OUT = BASE / 'out'
COMPAT = False
DIAGNOSTIC_LEVEL = False
RELAXED_LEVEL = False
GDI = False
THREADING_HASH = 'aa611155057ebd01cf315ad702a4b5725aa9d5e6fad87732c956fe0a1e5fcfba'
OVERRIDES = ('xgameruntime,windows.web,twinapi.appcore,windows.ui.core.textinput,wintypes=b;'
             'd3d12,d3d12core,d3d11,dxgi,d3d10core,winemetal=b;mscoree,mshtml=')


def safe_paths():
    for path in (BASE, WINE, PREFIX, GAME, LOGS, OUT):
        if path.is_symlink() or path.resolve() != path:
            raise RuntimeError(f'Unexpected linked experiment path: {path.name}')
    if not (WINE / 'bin/wine').is_file():
        raise RuntimeError('Run stage.py first.')
    for path in WINE.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(WINE):
            raise RuntimeError('Runtime symlink escapes the experiment.')


def writable_path(path):
    if not path.is_relative_to(BASE):
        raise RuntimeError('Write escapes experiment.')
    for parent in (path, *path.parents):
        if parent == BASE:
            break
        if parent.is_symlink():
            raise RuntimeError(f'Unexpected writable symlink: {parent}')
    return path


def environment(*, graphics=True):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('WINE', 'CX_', 'DYLD_', 'DXMT_', 'MULLION_', 'BEDROCK_'))}
    env.update(WINEPREFIX=str(PREFIX), WINEARCH='win64', WINEDEBUG='-all',
               WINEDLLOVERRIDES=OVERRIDES, LC_ALL='en_US.UTF-8',
               MULLION_LOG_PATH=str(LOGS), MULLION_CONFIG_FILE=str(BASE / 'mullion.conf'))
    if COMPAT and graphics:
        env.update(DYLD_INSERT_LIBRARIES=str(BASE / 'compat/metal32_fallback.dylib'),
                   MULLION_COMPAT_INTERNAL_SOURCE=str(BASE / 'compat/command-inlined.metal'))
    if DIAGNOSTIC_LEVEL:
        env['WINEDLLOVERRIDES'] = OVERRIDES.replace('d3d12,d3d12core,', 'd3d12core,') + ';d3d12=n'
        env['MULLION_DIAGNOSTIC_RETRY_FL12_0'] = '1'
    if RELAXED_LEVEL:
        env['MULLION_DIAGNOSTIC_RELAX_LEVELS'] = '1'
        env['MULLION_DIAGNOSTIC_TRACE_DXR'] = '1'
    if GDI:
        env['MULLION_CONFIG'] = 'dxgi.presentThroughGDI=True'
    env['WINESERVER'] = str(WINE / 'bin/wineserver')
    return env


def winpath(path):
    return 'Z:' + str(path).replace('/', '\\')


def fingerprint():
    paths = [WINE / 'bin/wine', WINE / 'lib/wine/x86_64-unix/winemetal.so',
             OUT / 'triangle.dxil', OUT / 'inline.dxil', OUT / 'dxr-render-probe.exe', BASE / 'mullion.conf',
             PREFIX / 'drive_c/windows/system32/xgameruntime.dll.threading']
    paths += [folder / name for folder in (WINE / 'lib/wine/x86_64-windows',
              PREFIX / 'drive_c/windows/system32') for name in
              ('d3d12.dll', 'd3d12core.dll', 'dxgi.dll', 'winemetal.dll')]
    if COMPAT:
        paths += [BASE / 'compat' / name for name in ('metal32_fallback.dylib', 'command-inlined.metal')]
    return {'files': {str(p.relative_to(BASE)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
            'compat': COMPAT, 'diagnostic_level': DIAGNOSTIC_LEVEL,
            'relaxed_level': RELAXED_LEVEL, 'gdi': GDI}


def require_dxr_pass():
    for filename in ('dxr-passed.json', 'inline-passed.json'):
        marker = OUT / filename
        if not marker.exists() or json.loads(marker.read_text()).get('fingerprint') != fingerprint():
            raise RuntimeError('Run both pipeline and inline ray-rendering probes with the current files first.')


def wine(*args, cwd=None, timeout=120):
    return subprocess.run([str(WINE / 'bin/wine'), *map(str, args)],
                          env=environment(), cwd=cwd or BASE,
                          check=True, timeout=timeout)


def stop_owned_server():
    subprocess.run([str(WINE / 'bin/wineserver'), '-k'], env=environment(graphics=False), timeout=15)
    subprocess.run([str(WINE / 'bin/wineserver'), '-w'], env=environment(graphics=False), timeout=15)


def initialize():
    wine('wineboot', '-u', timeout=180)
    # Keep host document directories outside this bottle's game and test data.
    for path in (PREFIX / 'drive_c/users').glob('*/*'):
        if path.is_symlink() and not path.resolve().is_relative_to(PREFIX):
            path.unlink()
            path.mkdir()
    system32 = PREFIX / 'drive_c/windows/system32'
    writable_path(system32)
    for name in ('dxcompiler.dll', 'dxil.dll'):
        shutil.copy2(BASE / 'dxc' / name, writable_path(system32 / name))
    # wineboot may retain built-in placeholders: explicitly stage only this prefix.
    for path in (BASE / 'mullion-v0.3/x86_64-windows').glob('*.dll'):
        shutil.copy2(path, writable_path(system32 / path.name))
    shutil.copy2(CLIENT / 'runtime/xgameruntime.dll.threading', writable_path(system32 / 'xgameruntime.dll.threading'))
    wine('reg', 'add', 'HKCU\\Software\\Wine', '/v', 'Version', '/d', 'win10', '/f')


def prepare_game():
    require_dxr_pass()
    if not GAME.exists():
        source = CLIENT / 'game'
        # Bounded, independent APFS copy; never clone the production bottle/saves.
        size = sum(p.stat().st_size for p in source.rglob('*') if p.is_file())
        if size > 3 * 1024**3:
            raise RuntimeError('Game exceeds the reviewed 3 GiB copy bound.')
        if any(p.is_symlink() for p in source.rglob('*')):
            raise RuntimeError('Game contains unexpected symlinks.')
        subprocess.run(['/bin/cp', '-cR', str(source), str(GAME)], check=True)
    system32 = PREFIX / 'drive_c/windows/system32'
    shutil.copy2(CLIENT / 'runtime/xgameruntime.dll.threading', writable_path(system32 / 'xgameruntime.dll.threading'))
    wine('reg', 'import', winpath(CLIENT_SCRIPTS / 'winrt.reg'))
    stop_owned_server()
    subprocess.run([sys.executable, str(CLIENT_SCRIPTS / 'standalone-gameinput.py'),
                    '--prefix', str(PREFIX), '--msi', str(GAME / 'Installers/GameInputRedist.msi'),
                    '--wineserver', str(WINE / 'bin/wineserver')], check=True)
    wine('reg', 'import', winpath(PREFIX / '.standalone-gameinput.reg'))
    fixture = BASE / 'fixture/build_fixture.py'
    if fixture.exists():
        subprocess.run([sys.executable, str(fixture)], check=True)
        profile = PREFIX / 'drive_c/users' / os.environ.get('USER', 'jake') / 'AppData/Roaming/Minecraft Bedrock/Users/Shared/games/com.mojang'
        for kind, name in [('resource_packs', 'Mullion_RayProof_RP'), ('behavior_packs', 'Mullion_RayProof_BP')]:
            target = profile / kind / name
            writable_path(target)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(BASE / 'fixture/out' / name, target, dirs_exist_ok=True)
    print('Separate Minecraft copy and empty game profile prepared.')


def launch_game():
    threading = PREFIX / 'drive_c/windows/system32/xgameruntime.dll.threading'
    if not threading.is_file() or hashlib.sha256(threading.read_bytes()).hexdigest() != THREADING_HASH:
        raise RuntimeError('Experimental native GDK threading DLL is missing or changed; rerun init.')
    require_dxr_pass()
    if not (GAME / 'Minecraft.Windows.exe').is_file():
        raise RuntimeError('Run game-setup first.')
    # The existing helper is account IPC only. No production bottle is launched.
    spec = importlib.util.spec_from_file_location('normal_readonly', CLIENT_SCRIPTS / 'standalone.py')
    normal = importlib.util.module_from_spec(spec)
    saved = {k: os.environ.pop(k) for k in ('BEDROCK_HOME', 'BEDROCK_BUNDLE') if k in os.environ}
    try:
        spec.loader.exec_module(normal)
    finally:
        os.environ.update(saved)
    helper = None
    helper_log = None
    owned_socket = None
    try:
        if not normal.account_ready():
            if os.path.lexists('/tmp/xodus.sock'):
                raise RuntimeError('Account socket is occupied; it was preserved.')
            helper_log = (LOGS / 'account-helper.log').open('w')
            env = environment(graphics=False)
            env.update(XODUS_LOG='off', RUST_LOG='off')
            helper = subprocess.Popen([str(normal.HELPER), '--serve', str(GAME)],
                                      env=env, stdout=helper_log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 300
            while not Path('/tmp/xodus.sock').exists():
                if helper.poll() is not None:
                    raise RuntimeError('Account helper stopped; see private account-helper.log.')
                if time.monotonic() > deadline:
                    raise RuntimeError('Account helper timed out.')
                time.sleep(1)
            info = Path('/tmp/xodus.sock').lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or helper.poll() is not None:
                raise RuntimeError('Account socket ownership/readiness failed.')
            owned_socket = (info.st_dev, info.st_ino)
            with socket.socket(socket.AF_UNIX) as check:
                check.settimeout(2)
                check.connect('/tmp/xodus.sock')
        # Give this experimental process its own app identity for UI QA.
        app = BASE / 'Mullion Bedrock QA.app'
        binary = writable_path(app / 'Contents/MacOS/wine')
        binary.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(WINE / 'lib/wine/x86_64-unix/wine', binary)
        ntdll = binary.parent / 'ntdll.so'
        if not ntdll.exists():
            ntdll.symlink_to(WINE / 'lib/wine/x86_64-unix/ntdll.so')
        if ntdll.resolve() != WINE / 'lib/wine/x86_64-unix/ntdll.so':
            raise RuntimeError('Unexpected experimental app loader link.')
        writable_path(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'wine', 'CFBundleIdentifier': 'local.bedrock.mullion-qa',
            'CFBundleName': 'Mullion Bedrock QA', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'NSHighResolutionCapable': True}))
        subprocess.run([str(binary), winpath(GAME / 'Minecraft.Windows.exe')],
                       cwd=GAME, env=environment(), timeout=None, check=True)
    finally:
        if helper is not None and helper.poll() is None:
            helper.terminate()
            try:
                helper.wait(timeout=10)
            except subprocess.TimeoutExpired:
                helper.kill()
                helper.wait()
        if helper_log is not None:
            helper_log.close()
        if owned_socket is not None:
            path = Path('/tmp/xodus.sock')
            try:
                info = path.lstat()
                if (info.st_dev, info.st_ino) == owned_socket:
                    with socket.socket(socket.AF_UNIX) as check:
                        check.settimeout(1)
                        try:
                            check.connect(str(path))
                        except ConnectionRefusedError:
                            if (path.lstat().st_dev, path.lstat().st_ino) == owned_socket:
                                path.unlink()
            except FileNotFoundError:
                pass


def worker(action):
    os.umask(0o077)
    safe_paths()
    OUT.mkdir(exist_ok=True)
    LOGS.mkdir(exist_ok=True)
    try:
        if action == 'init':
            initialize()
        elif action == 'build-probe':
            subprocess.run(['/bin/sh', str(BASE / 'probes/build.sh')], check=True)
        elif action == 'build-compat':
            subprocess.run(['/bin/sh', str(BASE / 'compat/build.sh')], check=True)
        elif action == 'build-loader':
            subprocess.run(['/bin/sh', str(BASE / 'compat/build-loader.sh')], check=True)
            target = writable_path(PREFIX / 'drive_c/windows/system32/d3d12.dll')
            backup = writable_path(PREFIX / 'drive_c/windows/system32/d3d12.dll.stock-mullion')
            if not backup.exists():
                shutil.copy2(target, backup)
            shutil.copy2(OUT / 'diagnostic-loader/d3d12.dll', target)
        elif action in ('shader', 'inline-shader'):
            inline = action == 'inline-shader'
            name = 'inline' if inline else 'triangle'
            wine(winpath(BASE / 'dxc/dxc.exe'), '-T', 'cs_6_5' if inline else 'lib_6_3', '-HV', '2018',
                 *(['-E', 'main'] if inline else []),
                 '-Fo', winpath(OUT / (name + '.dxil')), winpath(BASE / 'probes' / (name + '.hlsl')))
        elif action == 'capabilities':
            wine(winpath(OUT / 'dxr-render-probe.exe'), '--capabilities-only', cwd=OUT)
        elif action == 'presentation':
            shutil.copy2(CLIENT / 'runtime/standalone/probes/standalone-graphics-probe.exe', OUT / 'presentation.exe')
            wine(winpath(OUT / 'presentation.exe'), cwd=OUT, timeout=45)
        elif action in ('probe', 'inline-probe'):
            inline = action == 'inline-probe'
            name = 'inline' if inline else 'triangle'
            marker = OUT / ('inline-passed.json' if inline else 'dxr-passed.json')
            marker.unlink(missing_ok=True)
            report_path = OUT / ('inline-readback.txt' if inline else 'render-readback.txt')
            with report_path.open('w') as report:
                result = subprocess.run([str(WINE / 'bin/wine'), winpath(OUT / 'dxr-render-probe.exe'),
                                         *(['--inline'] if inline else []), winpath(OUT / (name + '.dxil'))], cwd=OUT, env=environment(),
                                        stdout=report, stderr=subprocess.STDOUT, timeout=120)
            output = report_path.read_text()
            print(output)
            expected = 'verdict.inline_ray_query_rendering: PASS' if inline else 'verdict.real_dxr_rendering: PASS'
            if result.returncode or expected not in output:
                raise RuntimeError('Actual ray readback did not pass.')
            # The executable must return nonzero for all mismatched ray readbacks.
            marker.write_text(json.dumps({
                'time': time.time(), 'versions': json.loads((BASE / 'versions.json').read_text()),
                'fingerprint': fingerprint()
            }, indent=2) + '\n')
        elif action == 'game-setup':
            prepare_game()
        elif action == 'game':
            launch_game()
    finally:
        stop_owned_server()


def main():
    global COMPAT, DIAGNOSTIC_LEVEL, RELAXED_LEVEL, GDI
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['init', 'build-probe', 'build-compat', 'build-loader', 'shader', 'inline-shader', 'capabilities', 'presentation', 'probe', 'inline-probe', 'game-setup', 'game', 'status'])
    parser.add_argument('--compat', action='store_true', help='Use isolated MSL 3.2 internal-library fallback')
    parser.add_argument('--diagnostic-level', action='store_true', help='Diagnostic lower device minimum; feature queries unchanged')
    parser.add_argument('--relaxed-level', action='store_true', help='Experimental FL12_0 aggregate profile, sparse tier remains zero')
    parser.add_argument('--gdi', action='store_true', help='Use GDI presentation to isolate Metal window-bridge faults')
    parser.add_argument('--unguarded-game', action='store_true',
                        help='Explicit game-only memory-guard override; retains isolation, job lock and telemetry')
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    COMPAT = args.compat
    RELAXED_LEVEL = args.relaxed_level
    DIAGNOSTIC_LEVEL = args.diagnostic_level or RELAXED_LEVEL
    GDI = args.gdi
    if args.unguarded_game and args.action != 'game':
        parser.error('--unguarded-game is only valid for game')
    if args.action == 'status':
        return subprocess.call([sys.executable, str(GUARD), '--status'])
    if args.worker:
        worker(args.action)
        return 0
    LOGS.mkdir(exist_ok=True, mode=0o700)
    LOGS.chmod(0o700)
    log_path = LOGS / (args.action + ('-compat' if COMPAT else '') + ('-relaxed' if RELAXED_LEVEL else '-diagnostic' if DIAGNOSTIC_LEVEL else '') + ('-gdi' if GDI else '') + '.log')
    command = [sys.executable, str(Path(__file__).resolve()), args.action, '--worker',
               *(['--compat'] if COMPAT else []),
               *(['--diagnostic-level'] if DIAGNOSTIC_LEVEL else []),
               *(['--relaxed-level'] if RELAXED_LEVEL else []),
               *(['--gdi'] if GDI else [])]
    if not args.unguarded_game:
        return subprocess.call([sys.executable, str(GUARD), '--log', str(log_path), '--', *command])
    # Explicit user override for this isolated game only. Do not modify the shared
    # guard or allow concurrent heavy QA. Observe host pressure without aborting.
    state = GUARD.parent.parent / 'work/qa-resource-guard'
    state.mkdir(parents=True, exist_ok=True)
    with (state / 'heavy-job.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with log_path.open('w') as log, (LOGS / 'game-host-memory.ndjson').open('w') as memory:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            print(json.dumps({'pid': process.pid, 'log': str(log_path), 'memory_abort': False}), flush=True)
            try:
                while process.poll() is None:
                    sample = {'time': time.time(), 'policy': 'observe only; explicit user override',
                              'pressure_level': int(subprocess.check_output(['sysctl', '-n', 'kern.memorystatus_vm_pressure_level'], text=True)),
                              'swap': subprocess.check_output(['sysctl', 'vm.swapusage'], text=True).strip()}
                    memory.write(json.dumps(sample)+'\n')
                    memory.flush()
                    (LOGS / 'game-host-memory-latest.json').write_text(json.dumps(sample)+'\n')
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        pass
            finally:
                if process.poll() is None:
                    import signal
                    os.killpg(process.pid, signal.SIGINT)
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGTERM)
                        process.wait(timeout=15)
            return process.returncode



if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.SubprocessError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
