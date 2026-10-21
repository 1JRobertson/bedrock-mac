#!/usr/bin/env python3
"""Build the tiny test packs beneath this fixture; never install into Minecraft."""
import json
from pathlib import Path
import shutil
import struct
import zlib
import zipfile

ROOT = Path(__file__).absolute().parent
OUT = ROOT / "out"
PACKS = {"resource_pack": "Mullion_RayProof_RP", "behavior_pack": "Mullion_RayProof_BP"}


def png(rgb):
    """Uniform 16x16 RGB texture, using only the Python standard library."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    pixels = (b"\x00" + bytes(rgb) * 16) * 16
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def main():
    if any(p.is_symlink() for p in (ROOT, *ROOT.parents)):
        raise RuntimeError("Fixture path must not contain symlinks")
    for source, name in PACKS.items():
        pack = OUT / name
        for item in (ROOT / source).rglob("*"):
            if item.is_symlink():
                raise RuntimeError("Fixture sources must not contain symlinks")
            if not item.is_file():
                continue
            if item.suffix == ".json":
                json.loads(item.read_text())
            target = pack / item.relative_to(ROOT / source)
            if any(p.is_symlink() for p in (target, *target.parents)):
                raise RuntimeError("Fixture output must not contain symlinks")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(item, target)
    textures = OUT / PACKS["resource_pack"] / "textures/blocks"
    for name, color in {"iron_block": (245, 245, 245), "redstone_block": (255, 8, 8),
                        "lapis_block": (8, 32, 255)}.items():
        destination = textures / (name + ".png")
        if destination.is_symlink():
            raise RuntimeError("Fixture output must not contain symlinks")
        destination.write_bytes(png(color))
    archive = OUT / "Mullion-RayProof.mcaddon"
    if archive.is_symlink():
        raise RuntimeError("Fixture archive must not be a symlink")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
        for name in PACKS.values():
            for path in sorted((OUT / name).rglob("*")):
                if path.is_symlink():
                    raise RuntimeError("Fixture output must not contain symlinks")
                if path.is_file():
                    package.write(path, path.relative_to(OUT))
    print(f"Built {archive} ({archive.stat().st_size} bytes); no installation performed.")


if __name__ == "__main__":
    main()
