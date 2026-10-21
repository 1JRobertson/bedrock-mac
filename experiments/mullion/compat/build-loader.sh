#!/bin/sh
# Builds only; never stages a DLL or changes any prefix.
set -eu
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CLIENT=${MULLION_CLIENT_ROOT:-$(CDPATH= cd -- "$BASE/../.." && pwd)}
WINE_BUILD="$CLIENT/build/standalone-wine"
WINE_SOURCE="$WINE_BUILD/source"
CLANG=/opt/homebrew/opt/llvm/bin/clang
export LC_ALL=en_US.UTF-8
export PATH="$WINE_BUILD/toolbin:/opt/homebrew/opt/llvm/bin:/usr/bin:/bin"
mkdir -p "$BASE/out/diagnostic-loader"
cd "$WINE_BUILD"
./tools/winegcc/winegcc -shared -o "$BASE/out/diagnostic-loader/d3d12.dll" --wine-objdir . \
    --cc-cmd="$CLANG -D__STDC__" -b x86_64-windows \
    "$BASE/compat/diagnostic-loader.spec" "$BASE/compat/diagnostic-loader.c" \
    -Iinclude -I"$WINE_SOURCE/include" -I"$WINE_SOURCE/include/msvcrt" \
    -D__WINESRC__ -nostdlib -Wl,-entry:DllMain \
    dlls/kernel32/x86_64-windows/libkernel32.a \
    dlls/ucrtbase/x86_64-windows/libucrtbase.a --no-default-config
