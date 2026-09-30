#!/bin/sh
# Rebuild only DXMT's Cocoa/Metal bridge, using the pinned upstream shader compiler.
# Does not install into a runtime. The C++ finish-thread patch is not built here.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT="$ROOT/build/dxmt-memory-unix"
SOURCE="$ROOT/sources/dxmt"
WINE_RUNTIME="${STANDALONE_WINE_RUNTIME:-$ROOT/runtime/standalone/wine}"
export LC_ALL=en_US.UTF-8
case "${1:-}" in
  --stage-existing-runtime)
    [ "$#" -eq 2 ] || { printf 'Expected target Wine runtime\n' >&2; exit 2; }
    exec /usr/bin/python3 "$ROOT/standalone-dxmt-unix.py" stage "$2" ;;
  --validate-runtime)
    [ "$#" -eq 2 ] || { printf 'Expected isolated test Wine runtime\n' >&2; exit 2; }
    exec /usr/bin/python3 "$ROOT/standalone-dxmt-unix.py" validate "$2" ;;
  --validate)
    [ "$#" -eq 1 ] || exit 2
    exec /usr/bin/python3 "$ROOT/standalone-dxmt-unix.py" validate-clone "$WINE_RUNTIME" ;;
  '') [ "$#" -eq 0 ] || exit 2 ;;
  *) printf 'Usage: %s [--validate | --validate-runtime TEST_RUNTIME | --stage-existing-runtime TARGET_RUNTIME]\n' "$0" >&2; exit 2 ;;
esac
mkdir -p "$OUTPUT"
/usr/bin/python3 - "$ROOT" "$OUTPUT" "$SOURCE" "$WINE_RUNTIME" <<'PY'
import hashlib,json,shutil,subprocess,sys
from pathlib import Path
root,output,source,runtime=map(Path,sys.argv[1:])
commit='589adb780354b461645b29999cefaf533594ee99'
expected='3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca'
upstream=root/'runtime/standalone/dxmt/x86_64-unix/winemetal.so'
if subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()!=commit:
    raise SystemExit('Expected pinned DXMT v0.80 source')
if hashlib.sha256(upstream.read_bytes()).hexdigest()!=expected:
    raise SystemExit('Upstream winemetal.so hash mismatch')
filename='src/winemetal/unix/winemetal_unix.c'
original=(source/filename).read_bytes()
if original!=subprocess.check_output(['git','-C',str(source),'show',f'{commit}:{filename}']):
    raise SystemExit('Upstream Unix bridge source was modified')
for table_name in ('__wine_unix_call_funcs','__wine_unix_call_wow64_funcs'):
    body=original.decode().split(f'const void *{table_name}[] = {{',1)[1].split('};',1)[0]
    entries=[line.strip().rstrip(',') for line in body.splitlines() if line.strip()]
    if len(entries)!=132 or entries[96]!='&_WMTGetDisplayDescription' or entries[101]!='&_WMTQueryDisplaySettingForLayer':
        raise SystemExit('Unexpected DXMT Unix-call table layout')
tree=output/'source'; target=tree/filename;target.parent.mkdir(parents=True,exist_ok=True)
target.write_bytes(original)
patch=(root/'patches/standalone-dxmt-memory-lifetime.patch').read_text()
unix_patch=patch.split('--- a/src/dxmt/dxmt_command_queue.cpp\n',1)[0]
subprocess.run(['git','apply','--unsafe-paths','--directory='+str(tree)],
               input=unix_patch,text=True,check=True)
patched=target.read_text()
if patched.count('CFRelease(tag_data);')!=3 or 'bool got_gamut' not in patched or patched.count('@autoreleasepool')!=2:
    raise SystemExit('Expected memory-lifetime fixes were not applied')
shutil.copy2(upstream,output/'winemetal-upstream.so')
for name in ('ntdll.so','winemac.so'):
    link=output/name
    if link.is_symlink(): link.unlink()
    elif link.exists(): raise SystemExit(f'Unexpected non-symlink: {link}')
    link.symlink_to((runtime/'lib/wine/x86_64-unix'/name).resolve())
PY
/usr/bin/clang -arch x86_64 -mmacosx-version-min=15.0 -std=gnu2x -fno-objc-arc -O2 -ObjC \
  -I "$SOURCE/include" -I "$SOURCE/src/winemetal/unix" \
  -I "$SOURCE/src/winemetal" -I "$SOURCE/src/airconv" \
  -c "$OUTPUT/source/src/winemetal/unix/winemetal_unix.c" -o "$OUTPUT/winemetal_unix_patched.o"
/usr/bin/clang -arch x86_64 -mmacosx-version-min=15.0 -std=c11 -O2 -Wall -Wextra \
  -c "$ROOT/standalone-dxmt-display-trace.c" -o "$OUTPUT/display-trace.o"
/usr/bin/clang -arch x86_64 -mmacosx-version-min=15.0 -dynamiclib \
  "$OUTPUT/winemetal_unix_patched.o" "$OUTPUT/display-trace.o" "$OUTPUT/winemetal-upstream.so" \
  "$WINE_RUNTIME/lib/wine/x86_64-unix/ntdll.so" "$WINE_RUNTIME/lib/wine/x86_64-unix/winemac.so" \
  -framework Cocoa -framework Metal -framework MetalFX -framework ColorSync -framework QuartzCore \
  -Wl,-install_name,@rpath/winemetal-memory.so -Wl,-rpath,@loader_path -o "$OUTPUT/winemetal.so"
/usr/bin/install_name_tool -change @rpath/winemetal.so @loader_path/winemetal-upstream.so \
  -id @rpath/winemetal.so "$OUTPUT/winemetal.so"
/usr/bin/codesign --force --sign - "$OUTPUT/winemetal.so" >/dev/null 2>&1
/usr/bin/clang -arch x86_64 -mmacosx-version-min=15.0 -std=gnu2x -fno-objc-arc -O2 -Wall -Wextra \
  -I "$SOURCE/src/winemetal" "$ROOT/standalone-dxmt-display-probe.m" \
  -framework Foundation -framework CoreGraphics -Wl,-rpath,@loader_path \
  -o "$OUTPUT/display-memory-probe"
/usr/bin/python3 "$ROOT/standalone-dxmt-unix.py" manifest
printf 'Built isolated Unix bridge: %s\n' "$OUTPUT"
printf 'Enable optional scalar counters with BEDROCK_DXMT_DISPLAY_TRACE=1.\n'
