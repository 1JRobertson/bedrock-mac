#!/usr/bin/env python3
"""Build a pinned x86_64 Wine dependency prefix in a new isolated directory.

Requires Python 3.12+, Xcode command-line tools, make, pkg-config and Rosetta.
Never installs into a system or live runtime. Retains exact source archives,
notices, build commands and hashes for corresponding-source preparation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent
LOCK = ROOT / "native-dependencies.lock.json"
EXTRA_NOTICES = {"freetype": (
    "docs/FTL.TXT", "docs/GPLv2.TXT", "src/bdf/README", "src/pcf/README",
    "src/base/fthash.c", "include/freetype/internal/fthash.h", "src/gzip/zlib.h",
    "src/autofit/ft-hb-ft.c", "src/autofit/ft-hb-decls.h",
    "src/autofit/ft-hb-types.h", "src/autofit/hb-script-list.h",
)}


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def inventory(prefix):
    result = {}
    for path in sorted(prefix.rglob("*")):
        relative = path.relative_to(prefix).as_posix()
        if relative == "dependency-manifest.json":
            continue
        if path.is_symlink():
            target = path.readlink()
            if target.is_absolute() or not path.resolve().is_relative_to(prefix.resolve()) or not path.exists():
                raise ValueError("Unsafe dependency link: " + relative)
            result[relative] = {"symlink": str(target)}
        elif path.is_file():
            result[relative] = {"sha256": digest(path)}
        elif not path.is_dir():
            raise ValueError("Unsupported dependency file: " + relative)
    return result


def verify(prefix):
    prefix = Path(prefix)
    if prefix.is_symlink():
        raise ValueError("Dependency prefix must not be a symlink")
    manifest = prefix / "dependency-manifest.json"
    if manifest.is_symlink():
        raise ValueError("Dependency manifest must not be a symlink")
    data = json.loads(manifest.read_text())
    if data.get("schema") != 1 or data.get("source_built") is not True or data.get("architecture") != "x86_64":
        raise ValueError("Unsupported dependency provenance")
    if data.get("lock_sha256") != digest(LOCK):
        raise ValueError("Dependency inputs differ from the reviewed source lock")
    if data.get("source_archives") != json.loads(LOCK.read_text())["components"]:
        raise ValueError("Dependency source inventory differs from the reviewed lock")
    if data.get("files") != inventory(prefix):
        raise ValueError("Dependency prefix differs from its manifest")
    for required in ("lib/libgnutls.30.dylib", "lib/libfreetype.6.dylib", "include/gnutls/gnutls.h", "include/freetype2/ft2build.h"):
        if not (prefix / required).is_file():
            raise ValueError("Missing dependency: " + required)
    return data


def run(command, log, env, cwd=None):
    with log.open("a") as output:
        output.write("COMMAND " + json.dumps(command) + "\n")
        output.flush()
        subprocess.run(command, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)


def relocate(prefix):
    """Keep only system absolute loads and contained relative library loads."""
    libraries = prefix / "lib"
    for library in sorted(libraries.glob("*.dylib")):
        if library.is_symlink():
            continue
        architecture = subprocess.check_output(["lipo", "-archs", str(library)], text=True).strip()
        if architecture != "x86_64":
            raise ValueError("Unexpected library architecture: " + library.name)
        lines = subprocess.check_output(["otool", "-L", str(library)], text=True).splitlines()[2:]
        for line in lines:
            old = line.strip().split(" (")[0]
            if old.startswith(str(libraries) + "/"):
                new = "@loader_path/" + Path(old).name
                subprocess.run(["install_name_tool", "-change", old, new, str(library)], check=True)
            else:
                new = old
            if new.startswith("@loader_path/"):
                dependency = (library.parent / new[len("@loader_path/"):]).resolve()
                if not dependency.is_relative_to(libraries.resolve()) or not dependency.is_file():
                    raise ValueError("Escaping or missing library dependency: " + new)
            elif not new.startswith(("/System/", "/usr/lib/")):
                raise ValueError("Untracked library dependency: " + new)
        commands = subprocess.check_output(["otool", "-l", str(library)], text=True).splitlines()
        for index, line in enumerate(commands):
            if line.strip() == "cmd LC_RPATH":
                path = commands[index + 2].strip().removeprefix("path ").rsplit(" (offset", 1)[0]
                subprocess.run(["install_name_tool", "-delete_rpath", path, str(library)], check=True)
        subprocess.run(["install_name_tool", "-id", "@rpath/" + library.name, str(library)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(library)], check=True, stderr=subprocess.DEVNULL)


def require_fresh_outputs(destination, sources, prefix):
    if (destination / "build-identity.json").exists() or any(sources.iterdir()) or any(prefix.iterdir()):
        raise ValueError("Existing build outputs are not reusable; use --verify or a new isolated destination")


def build_environment(destination, prefix, sdk, clang, pkg_config):
    # Autoconf honors numerous *_CFLAGS/*_LIBS and cache/site variables. Do not
    # inherit shell overrides or loader/preload settings into a source receipt.
    home, temporary = destination / "build-home", destination / "build-tmp"
    home.mkdir(exist_ok=True, mode=0o700)
    temporary.mkdir(exist_ok=True, mode=0o700)
    return dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", HOME=str(home), TMPDIR=str(temporary),
        SHELL="/bin/sh", CONFIG_SITE="/dev/null", LC_ALL="C", TZ="UTC",
        CC=f"{clang} -arch x86_64 -isysroot {sdk}", CFLAGS="-O2 -mmacosx-version-min=15.0",
        CPPFLAGS=f"-I{prefix}/include", LDFLAGS=f"-L{prefix}/lib -Wl,-rpath,{prefix}/lib -mmacosx-version-min=15.0",
        MACOSX_DEPLOYMENT_TARGET="15.0", PKG_CONFIG=pkg_config,
        PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"), PKG_CONFIG_PATH="",
        ZLIB_CFLAGS=f"-I{sdk}/usr/include", ZLIB_LIBS="-lz")


def build(destination, jobs, fetch_only=False):
    if not hasattr(tarfile, "data_filter"):
        raise ValueError("Source extraction requires Python 3.12 or newer")
    destination = destination.absolute()
    if destination.is_symlink():
        raise ValueError("Build destination must not be a symlink")
    destination.mkdir(parents=True, exist_ok=True)
    marker = destination / "source-lock.sha256"
    if marker.exists():
        if marker.read_text().strip() != digest(LOCK):
            raise ValueError("Existing build uses different pinned sources; choose a new directory")
    elif any(destination.iterdir()):
        raise ValueError("Use an empty isolated build destination")
    else:
        marker.write_text(digest(LOCK) + "\n")
    lock = json.loads(LOCK.read_text())
    downloads, sources, prefix, logs = (destination / name for name in ("downloads", "source", "prefix", "logs"))
    for path in (downloads, sources, prefix, logs):
        path.mkdir(exist_ok=True)
    for component in lock["components"]:
        archive = downloads / component["archive"]
        if archive.is_symlink():
            raise ValueError("Archive must not be a symlink")
        if not archive.exists():
            with tempfile.TemporaryDirectory(prefix=".fetch-", dir=downloads) as temporary:
                candidate = Path(temporary) / "source.tar"
                subprocess.run(["/usr/bin/curl", "--disable", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "--retry", "3", "--output", str(candidate), component["url"]], check=True)
                if digest(candidate) != component["sha256"]:
                    raise ValueError("Source digest mismatch: " + component["name"])
                candidate.replace(archive)
        if digest(archive) != component["sha256"]:
            raise ValueError("Source digest mismatch: " + component["name"])
    if fetch_only:
        return
    # Fetch-only caches may be reused after digest verification. Source/build
    # trees and installed outputs may not: a new manifest must never bless
    # edited cached headers, configure scripts or libraries.
    require_fresh_outputs(destination, sources, prefix)
    pkg_config = shutil.which(os.environ.get("PKG_CONFIG", "pkg-config"))
    if not pkg_config:
        raise ValueError("pkg-config is required; set PKG_CONFIG to its executable before building")
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    clang = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    env = build_environment(destination, prefix, sdk, clang, pkg_config)
    identity = {"builder_sha256": digest(Path(__file__)), "lock_sha256": digest(LOCK), "clang": subprocess.check_output([clang, "--version"], text=True).strip(), "sdk": sdk, "sdk_version": subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip(), "pkg_config_version": subprocess.check_output([pkg_config, "--version"], text=True).strip(), "pkg_config_sha256": digest(Path(pkg_config).resolve()), "environment": env}
    identity_path = destination / "build-identity.json"
    identity_path.write_text(json.dumps(identity, indent=2) + "\n")
    commands = []
    for component in lock["components"]:
        source = sources / component["source_dir"]
        complete = logs / (component["name"] + ".complete")
        command = [str(source / "configure"), "--prefix=" + str(prefix), "--build=aarch64-apple-darwin", "--host=x86_64-apple-darwin", "--enable-shared", "--disable-static", *component["configure"]]
        commands.append(command)
        with tarfile.open(downloads / component["archive"]) as archive:
            archive.extractall(sources, filter="data")
        log = logs / (component["name"] + ".log")
        run(command, log, env, source)
        run(["make", "-j", str(jobs)], log, env, source)
        run(["make", "install"], log, env, source)
        complete.write_text(component["sha256"] + "\n")
    relocate(prefix)
    for component in lock["components"]:
        source = sources / component["source_dir"]
        for path in source.rglob("*"):
            if path.is_file() and not path.is_symlink() and path.name.upper().startswith(("COPYING", "LICENSE", "NOTICE", "AUTHORS")):
                target = prefix / "notices" / component["name"] / path.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
        for relative in EXTRA_NOTICES.get(component["name"], ()):
            target = prefix / "notices" / component["name"] / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / relative, target)
    (prefix / "notices/ATTRIBUTION.txt").write_text(
        "This software uses the FreeType library from the FreeType Project "
        "(https://freetype.org), under the FreeType License (FTL). "
        "Its full license, copyrights and contributed-code notices are retained "
        "in notices/freetype. Other libraries retain their accompanying terms.\n")
    manifest = {"schema": 1, "source_built": True, "architecture": "x86_64", "minimum_macos": "15.0", "lock_sha256": digest(LOCK), "source_archives": lock["components"], "features": lock["features"], "build_commands": commands, "build_identity": identity, "tool_versions": {"clang": identity["clang"], "sdk": identity["sdk_version"]}, "files": inventory(prefix)}
    (prefix / "dependency-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    verify(prefix)
    print("Verified dependency prefix: " + str(prefix))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--verify", type=Path, metavar="PREFIX")
    parser.add_argument("--fetch-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    try:
        if args.verify:
            verify(args.verify)
            print("Verified dependency inputs")
        elif args.destination and 1 <= args.jobs <= 8:
            build(args.destination, args.jobs, args.fetch_only)
        else:
            parser.error("Use --verify PREFIX or --destination NEW_DIRECTORY with 1-8 jobs")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Dependency preparation stopped: {error}\n")


if __name__ == "__main__":
    main()
