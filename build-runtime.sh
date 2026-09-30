#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD="$ROOT/build/winegdk"
RUST_TOOLCHAIN=$(rustup run 1.98.0 rustc --print sysroot)
SDK=$(xcrun --show-sdk-path)
mkdir -p "$BUILD/toolbin" "$ROOT/logs"
cat > "$BUILD/toolbin/lld-link" <<EOF
#!/bin/sh
export DYLD_LIBRARY_PATH='$RUST_TOOLCHAIN/lib'
exec '$RUST_TOOLCHAIN/lib/rustlib/aarch64-apple-darwin/bin/rust-lld' -flavor link "\$@"
EOF
chmod +x "$BUILD/toolbin/lld-link"
export PATH="$BUILD/toolbin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/usr/bin:/bin:/opt/homebrew/bin:$PATH"
export CC="$(xcrun --find clang) -arch x86_64 -isysroot $SDK"
export CXX="$(xcrun --find clang++) -arch x86_64 -isysroot $SDK"
export LC_ALL=en_US.UTF-8
cd "$BUILD"
"$ROOT/sources/winegdk/configure" --host=x86_64-apple-darwin24 \
  --enable-win64 --with-mingw=/opt/homebrew/opt/llvm/bin/clang \
  --disable-tests --without-x --without-freetype \
  --without-gnutls --without-opengl --without-vulkan --without-gstreamer \
  --without-ffmpeg > "$ROOT/logs/runtime-configure.log" 2>&1
make -j6 dlls/xgameruntime/all dlls/windows.web/all dlls/twinapi.appcore/all \
  dlls/windows.ui.core.textinput/all dlls/wintypes/all \
  > "$ROOT/logs/runtime-build.log" 2>&1
