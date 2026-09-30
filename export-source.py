#!/usr/bin/env python3
"""Export reviewed source files only; never walk the private working tree."""

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile


# Add individually reviewed source files here. Directories and globs are forbidden.
# Both runtime paths and the source clones are deliberately absent.
ALLOWED_FILES = (
    ".gitignore",
    "README.md",
    "LICENSE",
    "THIRD_PARTY.md",
    "LICENSES/Wine-LGPL-2.1-or-later.txt",
    "LICENSES/Wine-NOTICE.txt",
    "LICENSES/dxmt-LICENSE.txt",
    "LICENSES/dxmt-DXVK-LICENSE.txt",
    "LICENSES/dxmt-LLVM-LICENSE.txt",
    "LICENSES/dxmt-MinGW-LICENSE.txt",
    "LICENSES/DXMT-embedded-NOTICES.txt",
    "Launch Bedrock.command",
    "Launch Standalone.command",
    "launch.py",
    "standalone.py",
    "standalone-setup.py",
    "standalone-gameinput.py",
    "STANDALONE-SETUP.md",
    "run-windows.sh",
    "build-helper.sh",
    "build-runtime.sh",
    "build-probes.sh",
    "build-standalone-wine.sh",
    "build-standalone-graphics.sh",
    "build-standalone-probes.sh",
    "standalone-graphics-notes.md",
    "stage-runtime.py",
    "bootstrap-sources.py",
    "export-source.py",
    "bedrock-helper.rs",
    "standalone-helper.rs",
    "prepare-owned-game.rs",
    "runtime-auth-probe.c",
    "graphics-probe.c",
    "standalone-graphics-probe.c",
    "store-callback-probe.c",
    "gameinput.reg",
    "winrt.reg",
    "patches/Cargo.lock",
    "patches/xodus-real-store-license.patch",
    "patches/winegdk-macos-local.patch",
    "patches/minecraft-store-callback.patch",
    "patches/standalone-wine-dxmt-abi.patch",
    "patches/standalone-wine-storage-linkage.patch",
    "patches/standalone-wine-idl-list.patch",
    "patches/keychain-cache.patch",
    "patches/unified-helper.patch",
    "docs/PUBLISHING.md",
    "tests/test_export_source.py",
    "tests/test_bootstrap_sources.py",
    "tests/test_standalone.py",
)
PRIVATE_ROOTS = frozenset({
    "sources", "downloads", "runtime", "logs", "bottles", "build", "game",
    ".git", "__pycache__", "exports",
})


def checked_relative(name):
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or str(path) != name
            or any(part in (".", "..") for part in path.parts)
            or path.parts[0] in PRIVATE_ROOTS or "\\" in name
            or "\n" in name or "\r" in name):
        raise ValueError("Unsafe export entry: " + repr(name))
    return path


def read_source(root, name):
    """Reject symlinks in every component, not just symlinks at the leaf."""
    relative = checked_relative(name)
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("Refusing symlink in export path: " + name)
    if not current.is_file() or not current.resolve().is_relative_to(root):
        raise ValueError("Missing regular source file: " + name)
    # Open each directory relative to its validated descriptor. O_NOFOLLOW on
    # every component also closes a parent-symlink swap between check and read.
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in relative.parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW,
                             dir_fd=directory)
    finally:
        os.close(directory)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Refusing non-regular source file: " + name)
        content = stream.read()
    try:
        content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("Refusing non-text source file: " + name) from exc
    if b"\0" in content:
        raise ValueError("Refusing binary source file: " + name)
    return content, 0o755 if info.st_mode & 0o111 else 0o644


def collect_sources(root, allowlist=ALLOWED_FILES):
    root = Path(root)
    if root.is_symlink():
        raise ValueError("The source root must not be a symlink")
    root = root.resolve(strict=True)
    if len(set(allowlist)) != len(allowlist):
        raise ValueError("Duplicate source export entry")
    return [(name, *read_source(root, name)) for name in allowlist]


def export_sources(root, destination, allowlist=ALLOWED_FILES):
    files = collect_sources(root, allowlist)
    destination = Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination already exists; choose a new directory")
    # Require an existing parent: do not silently create paths outside user intent.
    parent = destination.parent.resolve(strict=True)
    if not parent.is_dir():
        raise ValueError("Destination parent is not a directory")
    destination = parent / destination.name
    stage = Path(tempfile.mkdtemp(prefix=".bedrock-source-", dir=parent))
    try:
        digest_lines = []
        for name, content, mode in files:
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            target.chmod(mode)
            digest_lines.append(f"{hashlib.sha256(content).hexdigest()}  {name}\n")
        (stage / "SOURCE-SHA256.txt").write_text("".join(digest_lines), encoding="utf-8")
        # Rename is atomic on this volume. Never merge into an existing directory.
        if destination.exists() or destination.is_symlink():
            raise ValueError("Destination appeared during export")
        stage.rename(destination)
    except BaseException:
        shutil.rmtree(stage)
        raise
    return len(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", type=Path,
                        help="new output directory (its parent must exist)")
    parser.add_argument("--check", action="store_true", help="validate without writing")
    parser.add_argument("--list", action="store_true", help="print the reviewed allowlist")
    args = parser.parse_args()
    if args.list:
        print("\n".join(ALLOWED_FILES))
        return 0
    if args.check and args.destination:
        parser.error("--check does not take a destination")
    if not args.check and not args.destination:
        parser.error("provide a destination or --check")
    root = Path(__file__).resolve().parent
    try:
        if args.check:
            count = len(collect_sources(root))
            print(f"Validated {count} allowlisted source files; no runtime data read.")
        else:
            count = export_sources(root, args.destination)
            print(f"Exported {count} source files to {args.destination.absolute()}")
    except (ValueError, OSError) as exc:
        parser.exit(1, f"Source export refused: {exc}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
