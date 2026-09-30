#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/standalone-wine"
WINE="$ROOT/runtime/standalone/wine/bin/wine"
WINE_SERVER="$ROOT/runtime/standalone/wine/bin/wineserver"
PE_CC="${PE_CC:-/opt/homebrew/opt/llvm/bin/clang}"
export PATH="$BUILD/toolbin:$(dirname "$PE_CC"):$PATH"
export LC_ALL=en_US.UTF-8
export WINEPREFIX="$ROOT/runtime/standalone-wine-prefix"
export WINEDEBUG=-all
export WINEDLLOVERRIDES='winemac.drv=d;winemenubuilder.exe=d;mscoree=d;mshtml=d'

if [[ ! -x "$BUILD/tools/winegcc/winegcc" || ! -x "$WINE" ]]; then
    echo 'Build the standalone Wine runtime first.' >&2
    exit 1
fi
cd "$BUILD"
trap '"$WINE_SERVER" -k >/dev/null 2>&1 || true' EXIT
for TEST in claims realms; do
    ./tools/winegcc/winegcc -o "xuser-$TEST-test.exe" --wine-objdir . \
        --cc-cmd="$PE_CC -D__STDC__" -b x86_64-windows \
        "$ROOT/tests/xuser-$TEST.c" \
        -Isource/dlls/xgameruntime/GDKComponent/System \
        -Iinclude -Isource/include -Isource/include/msvcrt \
        -D__WINESRC__ -nostdlib -Wl,-entry:mainCRTStartup \
        dlls/kernel32/x86_64-windows/libkernel32.a \
        dlls/ucrtbase/x86_64-windows/libucrtbase.a \
        dlls/wininet/x86_64-windows/libwininet.a --no-default-config
    "$WINE" "$BUILD/xuser-$TEST-test.exe" >"xuser-$TEST-test.log" 2>&1
    cat "xuser-$TEST-test.log"
done
