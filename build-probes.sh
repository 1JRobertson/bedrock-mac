#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT/build/winegdk"
export PATH="$PWD/toolbin:/opt/homebrew/opt/llvm/bin:/usr/bin:/bin"
make -j6 include/d3d11.h include/dxgi.h include/dxgitype.h include/dxgiformat.h \
  include/dxgicommon.h include/d3dcommon.h include/d3d10_1.h include/d3d10.h \
  include/d3d10shader.h include/d3d10effect.h include/d3d10sdklayers.h
for PROBE in graphics-probe runtime-auth-probe store-callback-probe; do
  ./tools/winegcc/winegcc -o "$ROOT/runtime/$PROBE.exe" --wine-objdir . \
    --cc-cmd="/opt/homebrew/opt/llvm/bin/clang -D__STDC__" -b x86_64-windows \
    "$ROOT/$PROBE.c" -Iinclude -I"$ROOT/sources/winegdk/include" \
    -I"$ROOT/sources/winegdk/include/msvcrt" -D__WINESRC__ -nostdlib \
    -Wl,-entry:mainCRTStartup dlls/kernel32/x86_64-windows/libkernel32.a \
    dlls/ucrtbase/x86_64-windows/libucrtbase.a --no-default-config
done
# The GDK reads MicrosoftGame.Config beside the executable.
cp "$ROOT/runtime/runtime-auth-probe.exe" "$ROOT/game/runtime-auth-probe.exe"
cp "$ROOT/runtime/store-callback-probe.exe" "$ROOT/game/store-callback-probe.exe"
