#!/usr/bin/env python3
"""Compile and run synthetic WinHTTP POSTs in a new, private Wine prefix.

Run under tools/qa_resource_guard.py. This does not build/install Wine, launch
Minecraft, or access the account helper. --output must not already exist.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import threading

ROOT = Path(__file__).resolve().parents[1]


def serve(listener, results):
    """Require two exact POSTs on one HTTP/1.1 connection."""
    try:
        listener.settimeout(20)
        with listener.accept()[0] as peer:
            peer.settimeout(10)
            buffered = b''
            for index, size in ((1, 307), (2, 61)):
                while b'\r\n\r\n' not in buffered:
                    part = peer.recv(4096)
                    if not part or len(buffered) + len(part) > 16384:
                        raise ValueError('missing or oversized request headers')
                    buffered += part
                headers, buffered = buffered.split(b'\r\n\r\n', 1)
                lines = headers.split(b'\r\n')
                if lines[0] != f'POST /{index} HTTP/1.1'.encode():
                    raise ValueError('duplicate body bytes before next POST')
                lengths = [line.split(b':', 1)[1].strip() for line in lines[1:]
                           if line.lower().startswith(b'content-length:')]
                if lengths != [str(size).encode()]:
                    raise ValueError('incorrect Content-Length')
                while len(buffered) < size:
                    part = peer.recv(4096)
                    if not part:
                        raise ValueError('truncated request body')
                    buffered += part
                body, buffered = buffered[:size], buffered[size:]
                if body != (b'a' if index == 1 else b'b') * size:
                    raise ValueError('incorrect request body')
                results['posts'] += 1
                peer.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n')
            # The synthetic client exits after both responses. Read to EOF so
            # excess bytes in a later TCP segment cannot evade the assertion.
            if buffered or peer.recv(1):
                raise ValueError('extra body bytes after final POST')
    except (OSError, ValueError) as error:
        results['error'] = str(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wine-build', type=Path, default=ROOT / 'build/standalone-wine')
    parser.add_argument('--wine', type=Path, default=ROOT / 'runtime/standalone/wine/bin/wine')
    parser.add_argument('--winhttp', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build, wine, dll, output = (path.resolve() for path in
                                (args.wine_build, args.wine, args.winhttp, args.output))
    if not dll.is_file() or not wine.is_file():
        parser.error('Wine and the candidate WinHTTP DLL must exist')
    output.mkdir(parents=True, exist_ok=False)
    # Wine's loader redirects builtin PE DLLs to its own runtime directory.
    # Clone the runtime into new output, then replace only that clone's DLL.
    # APFS copy-on-write avoids copying the full runtime's bytes on macOS.
    subprocess.run(['/bin/cp', '-cR', str(wine.parent.parent), str(output / 'wine')], check=True)
    wine = output / 'wine/bin/wine'
    candidate = output / 'wine/lib/wine/x86_64-windows/winhttp.dll'
    if wine.is_symlink() or not wine.resolve().is_relative_to(output) or \
            not candidate.parent.resolve().is_relative_to(output):
        parser.error('Cloned Wine executable and DLL directory must stay inside the new output')
    # Break any copied symlink/hardlink before writing. Never follow a clone's
    # DLL link back to the installed runtime or generated source/build tree.
    candidate.unlink()
    shutil.copyfile(dll, candidate)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('WINE', 'DYLD_', 'CX_'))}
    env.update(LC_ALL='en_US.UTF-8', WINEDEBUG='-all', WINEARCH='win64',
               WINEPREFIX=str(output / 'prefix'),
               WINEDLLOVERRIDES='winhttp=b;winemac.drv=d;winemenubuilder.exe=d;mscoree=d;mshtml=d')
    env['PATH'] = str(build / 'toolbin') + ':/opt/homebrew/opt/llvm/bin:' + env['PATH']
    compiler = env.get('PE_CC', '/opt/homebrew/opt/llvm/bin/clang')
    command = [str(build / 'tools/winegcc/winegcc'), '-o', str(output / 'write-test.exe'),
               '--wine-objdir', '.', '--cc-cmd=' + compiler + ' -D__STDC__', '-b', 'x86_64-windows',
               str(ROOT / 'tests/winhttp-write-callbacks.c'), '-Wall', '-Wextra',
               '-Iinclude', '-Isource/include',
               '-Isource/include/msvcrt', '-D__WINESRC__', '-nostdlib', '-Wl,-entry:mainCRTStartup',
               'dlls/kernel32/x86_64-windows/libkernel32.a',
               'dlls/ucrtbase/x86_64-windows/libucrtbase.a',
               'dlls/winhttp/x86_64-windows/libwinhttp.a', '--no-default-config']
    report = {'winhttp_sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(),
              'client_sha256': hashlib.sha256((ROOT / 'tests/winhttp-write-callbacks.c').read_bytes()).hexdigest(),
              'compile_command': command, 'cases': []}
    with (output / 'compile.log').open('w') as log:
        subprocess.run(command, cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    try:
        # Initialize this newly owned prefix before the bounded loopback tests.
        with (output / 'prefix.log').open('w') as log:
            subprocess.run([str(wine), 'wineboot', '-u'], env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=90)
        for mode, name in enumerate(('synchronous', 'async-outside-callback', 'async-in-callback')):
            result = {'name': name, 'posts': 0}
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                listener.listen(1)
                worker = threading.Thread(target=serve, args=(listener, result), daemon=True)
                worker.start()
                command = [str(wine), str(output / 'write-test.exe'),
                           str(listener.getsockname()[1]), str(mode)]
                with (output / f'{name}.log').open('w') as log:
                    result['exit_code'] = subprocess.run(command, env=env, stdout=log,
                                                        stderr=subprocess.STDOUT, timeout=35).returncode
                worker.join(21)
                result['passed'] = (not worker.is_alive() and result['exit_code'] == 0
                                    and result['posts'] == 2 and 'error' not in result)
            report['cases'].append(result)
            print(json.dumps(result), flush=True)
    finally:
        # Only the server for the new test prefix; never the user's game prefix.
        subprocess.run([str(wine.with_name('wineserver')), '-k'], env=env, check=False)
        subprocess.run([str(wine.with_name('wineserver')), '-w'], env=env, check=True, timeout=15)
        (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    return int(not all(case['passed'] for case in report['cases']))


if __name__ == '__main__':
    raise SystemExit(main())
