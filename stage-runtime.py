#!/usr/bin/env python3
"""Stage the built compatibility runtime in our isolated CrossOver bottle."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import tempfile

root = Path(__file__).resolve().parent
cx = root / 'runtime/CrossOver.app/Contents/SharedSupport/CrossOver'
stage = root / 'runtime/winegdk'
build = root / 'build/winegdk'
bottle = root / 'bottles/Bedrock-Mac'
system32 = bottle / 'drive_c/windows/system32'
artifacts = [
    (build / 'dlls/xgameruntime/x86_64-windows/xgameruntime.dll', stage / 'x86_64-windows/xgameruntime.dll', False),
    (build / 'dlls/xgameruntime/x86_64-windows/xgameruntime.dll', system32 / 'xgameruntime.dll', False),
    (build / 'dlls/xgameruntime/xgameruntime.so', stage / 'x86_64-unix/xgameruntime.so', False),
    (build / 'dlls/windows.web/x86_64-windows/windows.web.dll', system32 / 'windows.web.dll', True),
    (build / 'dlls/twinapi.appcore/x86_64-windows/twinapi.appcore.dll', system32 / 'twinapi.appcore.dll', True),
    (build / 'dlls/windows.ui.core.textinput/x86_64-windows/windows.ui.core.textinput.dll', system32 / 'windows.ui.core.textinput.dll', True),
    (build / 'dlls/wintypes/x86_64-windows/wintypes.dll', system32 / 'wintypes.dll', True),
    (root / 'runtime/xgameruntime.dll.threading', system32 / 'xgameruntime.dll.threading', False),
]
for source, _, strip in artifacts:
    if not source.is_file():
        raise SystemExit(f'Missing {source}')
    if strip and source.read_bytes()[64:80] != b'Wine builtin DLL':
        raise SystemExit('Unexpected windows.web header')
hashes = {}
for source, target, strip in artifacts:
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=target.name + '.stage-', dir=target.parent)
    with os.fdopen(fd, 'w+b') as f, source.open('rb') as src:
        shutil.copyfileobj(src, f)
        if strip:
            f.seek(64)
            f.write(bytes(16))
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temp_name, source.stat().st_mode & 0o777)
    os.replace(temp_name, target)
    hashes[str(target.relative_to(root))] = hashlib.sha256(target.read_bytes()).hexdigest()
link = stage / 'x86_64-unix/ntdll.so'
if not link.exists():
    link.symlink_to(cx / 'lib/wine/x86_64-unix/ntdll.so')
conf = bottle / 'cxbottle.conf'
backup = conf.with_suffix('.conf.before-winegdk')
if not backup.exists():
    shutil.copy2(conf, backup)
text = conf.read_text()
marker = '\n;; Minecraft local runtime\n'
text = text.split(marker)[0]
paths = [stage, stage / 'x86_64-windows', cx / 'lib/wine/x86_64-windows', cx / 'lib/wine/i386-windows', cx / 'lib/wine']
text += marker + '[Wine]\n"DllPath" = "' + ':'.join(map(str, paths)) + '"\n'
conf.write_text(text)
(root / 'runtime/staged-hashes.json').write_text(json.dumps(hashes, indent=2) + '\n')
print('Staged Xbox runtime and Windows web parser.')
