#!/bin/bash
# Test the candidate DLL in its own runtime/prefix; never stage the game runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/standalone-wine"
CANDIDATE="$BUILD/refresh-runtime"
PROBES="$BUILD/refresh-probes"
PE_CC="${PE_CC:-/opt/homebrew/opt/llvm/bin/clang}"
export LC_ALL=en_US.UTF-8
export PATH="$BUILD/toolbin:$(dirname "$PE_CC"):$PATH"
export WINEPREFIX="$ROOT/runtime/standalone-refresh-prefix"
export WINEDEBUG=-all
export WINEDLLOVERRIDES='xgameruntime=b;winemac.drv=d;winemenubuilder.exe=d;mscoree=d;mshtml=d'
if [[ ! -S /tmp/xodus.sock || ! -f "$ROOT/game/MicrosoftGame.Config" ]]; then
    echo 'Start the signed-in local helper and install your owned game first.' >&2
    exit 1
fi
if [[ ! -d "$CANDIDATE" ]]; then
    /bin/cp -cR "$ROOT/runtime/standalone/wine" "$CANDIDATE"
fi
WINE="$CANDIDATE/bin/wine"
WINE_SERVER="$CANDIDATE/bin/wineserver"
"$WINE_SERVER" -k >/dev/null 2>&1 || true
"$WINE_SERVER" -w
trap '"$WINE_SERVER" -k >/dev/null 2>&1 || true' EXIT
mkdir -p "$PROBES"
/bin/cp -c "$BUILD/dlls/xgameruntime/x86_64-windows/xgameruntime.dll" \
    "$CANDIDATE/lib/wine/x86_64-windows/xgameruntime.dll.next"
mv "$CANDIDATE/lib/wine/x86_64-windows/xgameruntime.dll.next" \
    "$CANDIDATE/lib/wine/x86_64-windows/xgameruntime.dll"

cd "$BUILD"
./tools/winegcc/winegcc -o "$PROBES/xuser-rta-live.exe" --wine-objdir . \
    --cc-cmd="$PE_CC -D__STDC__" -b x86_64-windows \
    "$ROOT/tests/xuser-rta-live.c" -I"$PROBES" \
    -Iinclude -Isource/include -Isource/include/msvcrt \
    -D__WINESRC__ -nostdlib -Wl,-entry:mainCRTStartup \
    dlls/kernel32/x86_64-windows/libkernel32.a \
    dlls/ucrtbase/x86_64-windows/libucrtbase.a \
    dlls/winhttp/x86_64-windows/libwinhttp.a --no-default-config
cp "$ROOT/game/MicrosoftGame.Config" "$PROBES/MicrosoftGame.Config"
if [[ ! -f "$WINEPREFIX/system.reg" ]]; then
    "$WINE" wineboot -u >"$PROBES/prefix-setup.log" 2>&1
fi
cp "$ROOT/runtime/xgameruntime.dll.threading" "$WINEPREFIX/drive_c/windows/system32/"
WINEDEBUG=-all,+xuser "$WINE" "$PROBES/xuser-rta-live.exe" >"$PROBES/rta-live.log" 2>&1
# Only booleans/status and safe refresh markers are shown. Full diagnostic trace
# remains local and never prints token or signature contents.
tr -d '\r' <"$PROBES/rta-live.log" | sed -n '/=0x[0-9A-F]*$/p; /=true$/p; /=false$/p; /Renewing .*token/p'
