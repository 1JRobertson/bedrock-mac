#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$here/inline_command.py"
xcrun clang -arch x86_64 -dynamiclib -O2 -fno-objc-arc \
  -framework Foundation -framework Metal \
  "$here/metal32_fallback.m" -o "$here/metal32_fallback.dylib"
