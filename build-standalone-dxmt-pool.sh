#!/bin/sh
# Build an isolated diagnostic adapter. Staging is explicit and uses tested bytes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT="$ROOT/build/dxmt-autorelease-shim"
UPSTREAM="$ROOT/runtime/standalone/dxmt/x86_64-unix/winemetal.so"
export LC_ALL=en_US.UTF-8
if [ "${1:-}" = "--stage-existing-runtime" ] && [ "$#" -eq 2 ]; then
  /usr/bin/python3 - "$ROOT" "$OUTPUT" "$2" <<'PY'
import hashlib,json,os,shutil,sys,tempfile
from pathlib import Path
root, output, runtime = map(Path, sys.argv[1:])
runtime = runtime.resolve()
metadata = json.loads((output/'adapter-manifest.json').read_text())
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
if digest(root/'standalone-dxmt-autorelease-shim.m') != metadata['source_sha256']:
    raise SystemExit('Adapter source changed; rebuild and validate before staging')
for filename in ('winemetal.so','winemetal-upstream.so'):
    if digest(output/filename) != metadata['files'][filename]:
        raise SystemExit(f'Adapter artifact changed: {filename}')
target = runtime/'lib/wine/x86_64-unix'
if not (runtime/'bin/wine').is_file() or not (target/'winemetal.so').is_file():
    raise SystemExit('Expected an existing standalone Wine runtime with DXMT installed')
allowed = {metadata['files']['winemetal.so'],metadata['files']['winemetal-upstream.so']}
if digest(target/'winemetal.so') not in allowed:
    raise SystemExit('Refusing to replace an unknown winemetal.so')
for filename in ('winemetal-upstream.so','winemetal.so'):
    fd, temporary = tempfile.mkstemp(prefix=f'.{filename}.',dir=target)
    os.close(fd)
    try:
        shutil.copy2(output/filename,temporary)
        os.replace(temporary,target/filename)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
(runtime/'dxmt-pool-adapter.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(f'Staged experimental adapter into {runtime}')
print('Use BEDROCK_DXMT_DISPLAY_QUERY_POOL=0 for control, 1 for the candidate.')
PY
  exit 0
fi
if [ "$#" -ne 0 ]; then
  printf 'Usage: %s [--stage-existing-runtime WINE_RUNTIME]\n' "$0" >&2
  printf 'Build with no arguments, validate it, then stage while the target runtime is stopped.\n' >&2
  exit 2
fi
mkdir -p "$OUTPUT"
/usr/bin/python3 - "$ROOT" "$UPSTREAM" "$OUTPUT" <<'PY'
import hashlib,json,re,shutil,sys
from pathlib import Path
root, upstream, output = map(Path, sys.argv[1:])
manifest = json.loads((root/'runtime/standalone/dxmt/manifest.json').read_text())
expected = '3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca'
if manifest['version'] != 'v0.80' or manifest['source_commit'] != '589adb780354b461645b29999cefaf533594ee99':
    raise SystemExit('Adapter requires the pinned DXMT v0.80 ABI')
if manifest['files']['x86_64-unix/winemetal.so'] != expected or hashlib.sha256(upstream.read_bytes()).hexdigest() != expected:
    raise SystemExit('Upstream winemetal.so hash mismatch')
source = (root/'sources/dxmt/src/winemetal/unix/winemetal_unix.c').read_text()
for name in ('__wine_unix_call_funcs','__wine_unix_call_wow64_funcs'):
    table = source.split(f'const void *{name}[] = {{',1)[1].split('};',1)[0]
    entries = [line.strip().rstrip(',') for line in table.splitlines() if line.strip()]
    if len(entries) != 132 or entries[101] != '&_WMTQueryDisplaySettingForLayer':
        raise SystemExit('Unexpected DXMT Unix-call table layout')
shutil.copyfile(upstream, output/'winemetal-upstream.so')
(output/'upstream-provenance.json').write_text(json.dumps({
    'version':manifest['version'], 'source_commit':manifest['source_commit'],
    'upstream_sha256':expected, 'abi_entries':132, 'wrapped_entry':101,
    'wrapped_function':'WMTQueryDisplaySettingForLayer',
    'status':'Experimental diagnostic adapter; not installed into the gameplay runtime.'
},indent=2)+'\n')
PY
/usr/bin/clang -arch x86_64 -mmacosx-version-min=15.0 -fno-objc-arc \
  -fvisibility=hidden -O2 -Wall -Wextra -dynamiclib \
  "$ROOT/standalone-dxmt-autorelease-shim.m" -framework Foundation \
  -Wl,-install_name,@rpath/winemetal.so -Wl,-rpath,@loader_path \
  -o "$OUTPUT/winemetal.so"
/usr/bin/codesign --force --sign - "$OUTPUT/winemetal.so" >/dev/null 2>&1
/usr/bin/python3 - "$ROOT" "$OUTPUT" <<'PY'
import hashlib,json,sys
from pathlib import Path
root, output = map(Path,sys.argv[1:])
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
metadata = json.loads((output/'upstream-provenance.json').read_text())
metadata.update(source_sha256=digest(root/'standalone-dxmt-autorelease-shim.m'),
                files={name:digest(output/name) for name in ('winemetal.so','winemetal-upstream.so')})
(output/'adapter-manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
PY
printf 'Built isolated diagnostic adapter: %s\n' "$OUTPUT"
