#!/bin/sh
# Compile the patched WineGDK source without any CrossOver binaries.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD="$ROOT/build/standalone-wine"
PREFIX="$ROOT/runtime/standalone/wine"
JOBS=${STANDALONE_JOBS:-3}
SOURCE="$BUILD/source"
# Refuse runtime mutation while a prefix is using these installed Unix libraries.
if [ -f "$PREFIX/lib/wine/x86_64-unix/ntdll.so" ] &&
   /usr/sbin/lsof -t "$PREFIX/lib/wine/x86_64-unix/ntdll.so" 2>/dev/null | read -r runtime_pid; then
  printf 'Close standalone Wine applications before rebuilding this runtime.\n' >&2
  exit 1
fi
mkdir -p "$BUILD/toolbin" "$BUILD/downloads" "$PREFIX/lib"
export LC_ALL=en_US.UTF-8
DEPS="$BUILD/downloads/wine-devel-11.8-osx64.tar.xz"
if [ ! -f "$DEPS" ]; then
  curl -fL --retry 3 "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.8/wine-devel-11.8-osx64.tar.xz" -o "$DEPS"
fi
python3 - "$DEPS" "$PREFIX/lib" "$BUILD/dependency-unused" <<'PYDEPS'
import hashlib, os, pathlib, subprocess, sys, tarfile
archive, destination, spare = map(pathlib.Path, sys.argv[1:])
expected = "5c9f0984961ee6289f4f2c4fe751c27f02b6c28855154e3f99b7e2bd8108b620"
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit("Wine dependency archive SHA256 mismatch")
# Extract only portable open-source dependencies; Wine itself is compiled below.
with tarfile.open(archive, "r|xz") as tf:
    for member in tf:
        if not (member.name.startswith("Wine Devel.app/Contents/Resources/wine/lib/")
                and member.name.count("/") == 5 and member.name.endswith(".dylib")):
            continue
        output = destination / pathlib.Path(member.name).name
        if member.issym():
            if pathlib.Path(member.linkname).name != member.linkname:
                raise SystemExit("Unsafe dependency symlink")
            if not output.exists() and not output.is_symlink():
                output.symlink_to(member.linkname)
        elif member.isfile():
            output.write_bytes(tf.extractfile(member).read())
            output.chmod(member.mode)
# Keep the transitive library closure actually used by this Wine configuration.
# Preserve other archive files in the build cache instead of shipping them.
needed = set()
pending = ["libgnutls.30.dylib", "libfreetype.6.dylib", "libgnutls.dylib", "libfreetype.dylib"]
while pending:
    name = pending.pop()
    if name in needed:
        continue
    needed.add(name)
    library = destination / name
    if library.is_symlink():
        pending.append(library.readlink().name)
    dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(library)], text=True)
    for line in dependencies.splitlines()[2:]:
        dependency = line.strip().split(" (")[0]
        if dependency.startswith(("@loader_path/", "@rpath/")):
            pending.append(pathlib.Path(dependency).name)
        elif not dependency.startswith(("/System/", "/usr/lib/")):
            raise SystemExit("Unexpected portable dependency: " + dependency)
spare.mkdir(exist_ok=True)
for library in destination.glob("*.dylib"):
    if library.name not in needed:
        os.replace(library, spare / library.name)
PYDEPS
# Build tools link FreeType directly; a bare dylib install name fails after
# macOS strips DYLD environment variables when executing system shells.
install_name_tool -id '@rpath/libfreetype.6.dylib' "$PREFIX/lib/libfreetype.6.dylib"
codesign --force --sign - "$PREFIX/lib/libfreetype.6.dylib" >/dev/null 2>&1
if [ ! -d "$SOURCE" ]; then
  cp -cRp "$ROOT/sources/winegdk" "$SOURCE"
fi
for PATCH in "$ROOT"/patches/standalone-wine-*.patch; do
  if ! git -C "$SOURCE" apply --reverse --check "$PATCH" 2>/dev/null; then
    git -C "$SOURCE" apply --check "$PATCH"
    git -C "$SOURCE" apply "$PATCH"
  fi
done
RUST_TOOLCHAIN=$(rustup run 1.98.0 rustc --print sysroot)
SDK=$(xcrun --show-sdk-path)
cat > "$BUILD/toolbin/lld-link" <<EOF
#!/bin/sh
export DYLD_LIBRARY_PATH='$RUST_TOOLCHAIN/lib'
exec '$RUST_TOOLCHAIN/lib/rustlib/aarch64-apple-darwin/bin/rust-lld' -flavor link "\$@"
EOF
chmod +x "$BUILD/toolbin/lld-link"
export PATH="$BUILD/toolbin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/usr/bin:/bin:/opt/homebrew/bin:$PATH"
export CC="$(xcrun --find clang) -arch x86_64 -isysroot $SDK"
export CXX="$(xcrun --find clang++) -arch x86_64 -isysroot $SDK"
export OBJC="$CC"
export CFLAGS='-O2'
export CXXFLAGS='-O2'
export OBJCFLAGS='-O2'
export CROSSCFLAGS='-O2'
export LC_ALL=en_US.UTF-8
# The installed Homebrew packages provide architecture-independent headers only.
# All linked third-party libraries come from the pinned x86_64 dependency archive.
export GNUTLS_CFLAGS="-I/opt/homebrew/opt/gnutls/include"
export GNUTLS_LIBS="-L$PREFIX/lib -lgnutls"
export FREETYPE_CFLAGS="-I/opt/homebrew/opt/freetype/include/freetype2"
export FREETYPE_LIBS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib -lfreetype"
export DYLD_FALLBACK_LIBRARY_PATH="$PREFIX/lib:/usr/lib"
# Portable install names avoid configure misparsing dylibs with bare Mach-O IDs.
export ac_cv_lib_soname_gnutls='@loader_path/../../libgnutls.30.dylib'
export ac_cv_lib_soname_freetype='@loader_path/../../libfreetype.6.dylib'
cd "$BUILD"
"$SOURCE/configure" --host=x86_64-apple-darwin24 \
  --prefix="$PREFIX" --enable-win64 \
  --with-mingw=/opt/homebrew/opt/llvm/bin/clang --disable-tests \
  --without-x --with-freetype --with-gnutls --without-vulkan \
  --without-gstreamer --without-ffmpeg > "$BUILD/configure.log" 2>&1
make -j"$JOBS" > "$BUILD/build.log" 2>&1
make install > "$BUILD/install.log" 2>&1
python3 - "$ROOT" "$PREFIX" "$SOURCE" <<'PYMANIFEST'
import hashlib, json, pathlib, subprocess, sys
root, prefix, source = map(pathlib.Path, sys.argv[1:])
manifest = {
    "wine_source_repository": "https://github.com/Sightem/WineGDK",
    "wine_source_revision": subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip(),
    "wine_version": subprocess.check_output([str(prefix / "bin/wine"), "--version"], text=True).strip(),
    "architecture": "x86_64",
    "dependency_archive": {
        "url": "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.8/wine-devel-11.8-osx64.tar.xz",
        "sha256": "5c9f0984961ee6289f4f2c4fe751c27f02b6c28855154e3f99b7e2bd8108b620",
        "extracted": "GnuTLS/FreeType dylibs and their transitive dependencies; Wine compiled locally"
    },
    "patches": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (root / "patches").glob("standalone-wine*.patch")},
    "required_portable_libraries": sorted(p.name for p in (prefix / "lib").glob("*.dylib")),
    "capabilities": {"win64": True, "win32": False, "macdriver": True, "coreaudio": True,
                     "gnutls": True, "freetype": True, "gstreamer": False, "vulkan": False},
    "graphics": "Run build-standalone-graphics.sh --wine-runtime with this prefix after rebuilding Wine; validate graphics before gameplay."
}
(prefix / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PYMANIFEST
printf 'Built standalone Wine: %s\n' "$PREFIX/bin/wine"
