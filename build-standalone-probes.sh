#!/bin/sh
# Compile diagnostics against the standalone Wine build; does not launch Wine.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WINE_BUILD=${STANDALONE_WINE_BUILD:-"$ROOT/build/standalone-wine"}
WINE_SOURCE=${STANDALONE_WINE_SOURCE:-"$WINE_BUILD/source"}
CLANG=${STANDALONE_PE_CC:-/opt/homebrew/opt/llvm/bin/clang}
OUTPUT="$ROOT/runtime/standalone/probes"
export LC_ALL=en_US.UTF-8
export PATH="$WINE_BUILD/toolbin:/opt/homebrew/opt/llvm/bin:/usr/bin:/bin"

for REQUIRED in "$WINE_BUILD/tools/winegcc/winegcc" \
  "$WINE_BUILD/dlls/kernel32/x86_64-windows/libkernel32.a" \
  "$WINE_BUILD/dlls/user32/x86_64-windows/libuser32.a" \
  "$WINE_BUILD/dlls/ucrtbase/x86_64-windows/libucrtbase.a" \
  "$WINE_BUILD/include/d3d11.h" "$WINE_BUILD/include/xuser.h"; do
  if [ ! -f "$REQUIRED" ]; then
    printf 'Complete the standalone Wine build first: missing %s\n' "$REQUIRED" >&2
    exit 1
  fi
done

mkdir -p "$OUTPUT"
cd "$WINE_BUILD"
for PROBE in standalone-graphics-probe runtime-auth-probe store-callback-probe; do
  ./tools/winegcc/winegcc -o "$OUTPUT/$PROBE.exe" --wine-objdir . \
    --cc-cmd="$CLANG -D__STDC__" -b x86_64-windows \
    "$ROOT/$PROBE.c" -Iinclude -I"$WINE_SOURCE/include" \
    -I"$WINE_SOURCE/include/msvcrt" -D__WINESRC__ -nostdlib \
    -Wl,-entry:mainCRTStartup dlls/kernel32/x86_64-windows/libkernel32.a \
    dlls/user32/x86_64-windows/libuser32.a \
    dlls/ucrtbase/x86_64-windows/libucrtbase.a --no-default-config
done
# GDK resolves title configuration beside the probe executable. This is an
# unmodified local copy of the owner's installed game's metadata, not a payload
# to include in source releases. The original game directory is never changed.
if [ -f "$ROOT/game/MicrosoftGame.Config" ]; then
  cp "$ROOT/game/MicrosoftGame.Config" "$OUTPUT/MicrosoftGame.Config"
else
  printf 'Game config missing; account probes need it before running.\n' >&2
fi
printf 'Built standalone probes: %s\n' "$OUTPUT"
