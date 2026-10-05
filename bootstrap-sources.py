#!/usr/bin/env python3
"""Fetch pinned upstream source trees and apply the reviewed local patches."""

import argparse
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent
PROJECTS = {
    "xodus": {
        "url": "https://github.com/xodus-gaming/xodus.git",
        "commit": "0670e25aeb0e0e9f800f8f2f4968ae3b681842a7",
        "patches": ("xodus-real-store-license.patch", "keychain-cache.patch", "unified-helper.patch", "standalone-signin-window.patch", "standalone-keychain-write.patch"),
    },
    "winegdk": {
        "url": "https://github.com/Sightem/WineGDK.git",
        "commit": "b5d23b074cfd5e28e79acceaaefaf41a26ce6272",
        "patches": ("winegdk-macos-local.patch", "minecraft-store-callback.patch"),
    },
    "dxmt": {
        "url": "https://github.com/3Shain/dxmt.git",
        "commit": "589adb780354b461645b29999cefaf533594ee99",
        "patches": (),
    },
}


def run(*args, cwd=None, capture=False):
    return subprocess.run(args, cwd=cwd, check=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def patch_paths(patches):
    paths = set()
    for patch in patches:
        for line in patch.read_text(encoding="utf-8").splitlines():
            match = re.match(r"^(?:--- a/|\+\+\+ b/)([^\t]+)(?:\t.*)?$", line)
            if not match:
                continue
            name = match.group(1)
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or str(path) != name or "\\" in name:
                raise ValueError("Unsafe patch path: " + name)
            paths.add(name)
    return sorted(paths)


def apply_project(root, name, project, source_root=ROOT):
    for patch in project["patches"]:
        file = source_root / "patches" / patch
        run("git", "apply", "--check", str(file), cwd=root)
        run("git", "apply", str(file), cwd=root)
    if name == "xodus":
        shutil.copyfile(source_root / "patches/Cargo.lock", root / "Cargo.lock")


def bootstrap(destination, names, source_root=ROOT):
    destination = Path(destination).absolute()
    if destination.is_symlink():
        raise ValueError("Source destination must not be a symlink")
    destination.mkdir(parents=True, exist_ok=True)
    destination = destination.resolve()
    for name in names:
        target = destination / name
        if target.exists() or target.is_symlink():
            raise ValueError(f"{target} already exists; use --check to verify it")
    for name in names:
        project = PROJECTS[name]
        temp = Path(tempfile.mkdtemp(prefix=f".{name}-bootstrap-", dir=destination))
        try:
            run("git", "init", "--quiet", str(temp))
            run("git", "remote", "add", "origin", project["url"], cwd=temp)
            run("git", "fetch", "--depth", "1", "origin", project["commit"], cwd=temp)
            run("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=temp)
            actual = run("git", "rev-parse", "HEAD", cwd=temp, capture=True).decode().strip()
            if actual != project["commit"]:
                raise ValueError(f"Unexpected {name} source revision")
            apply_project(temp, name, project, source_root)
            if (destination / name).exists() or (destination / name).is_symlink():
                raise ValueError(f"Destination {name} appeared during preparation")
            temp.rename(destination / name)
        except BaseException:
            shutil.rmtree(temp)
            raise
        print(f"Prepared {name} at {project['commit']}", flush=True)


def verify_project(repository, name, project, source_root=ROOT):
    """Replay patches in a tiny temporary tree; never modify an installed checkout."""
    repository = Path(repository)
    if repository.is_symlink():
        raise ValueError("Refusing a symlink source checkout")
    actual = run("git", "rev-parse", "HEAD", cwd=repository, capture=True).decode().strip()
    if actual != project["commit"]:
        raise ValueError(f"{name} is not at the pinned source revision")
    patches = [source_root / "patches" / patch for patch in project["patches"]]
    paths = patch_paths(patches)
    tracked = {}
    for entry in run("git", "ls-tree", "-rz", project["commit"],
                     cwd=repository, capture=True).decode().split("\0"):
        if entry:
            metadata, path = entry.split("\t", 1)
            tracked[path] = metadata.split()[0]
    with tempfile.TemporaryDirectory(prefix="bedrock-source-check-") as temp:
        prepared = Path(temp)
        for path in paths:
            if path in tracked:
                target = prepared / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(run("git", "show", project["commit"] + ":" + path,
                                       cwd=repository, capture=True))
                target.chmod(0o755 if tracked[path] == "100755" else 0o644)
        apply_project(prepared, name, project, source_root)
        if name == "xodus":
            paths.append("Cargo.lock")
        for path in paths:
            target = repository / path
            if target.is_symlink() or not target.is_file():
                raise ValueError(f"Missing regular patched source file: {name}/{path}")
            if target.read_bytes() != (prepared / path).read_bytes():
                raise ValueError(f"Source differs from preserved patches: {name}/{path}")
    return len(paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=ROOT / "sources")
    parser.add_argument("--project", choices=("all", *PROJECTS), default="all")
    parser.add_argument("--check", action="store_true",
                        help="verify existing patched files offline, without changing them")
    args = parser.parse_args()
    names = tuple(PROJECTS) if args.project == "all" else (args.project,)
    try:
        if args.check:
            for name in names:
                count = verify_project(args.destination / name, name, PROJECTS[name])
                print(f"Verified {name}: pinned revision and {count} patched files")
        else:
            bootstrap(args.destination, names)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Source preparation stopped: {exc}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
