# Preparing a source release

The public source repository is
[1JRobertson/bedrock-mac](https://github.com/1JRobertson/bedrock-mac). The commands
below prepare and verify source locally; they do not push or create a release.
Export only reviewed client source, not this entire development directory or
any adjacent server repository. Read [THIRD_PARTY.md](../THIRD_PARTY.md) for
component notices and [RELEASE.md](RELEASE.md) for binary release gates.

## Update the source inventory

Every new public file, including documentation and `AGENTS.md`, must be added
individually to `ALLOWED_FILES` in `export-source.py`. Check its contents before
adding it. The tracked `SOURCE-SHA256.txt` lists those files; it does not include
itself, generated output, or private data. CI verifies it, so regenerate it after
the last source/documentation edit:

```sh
python3 - <<'PY'
from pathlib import Path
import hashlib, os, runpy
collect = runpy.run_path('export-source.py')['collect_sources']
files = collect(Path.cwd())
temporary = Path('SOURCE-SHA256.txt.new')
with temporary.open('x', encoding='utf-8') as output:
    for name, contents, _mode in files:
        output.write(f'{hashlib.sha256(contents).hexdigest()}  {name}\n')
os.replace(temporary, 'SOURCE-SHA256.txt')
print('Inventoried source files:', len(files))
PY
shasum -a 256 -c SOURCE-SHA256.txt
```

If `.new` already exists, inspect and preserve it before retrying. Do not use
recursive filesystem hashing: it can enumerate account data, worlds, binaries,
or ignored logs. `--check` validates source boundaries but does not refresh the
tracked inventory. An export generates its own inventory in the destination.

## Validate and export

From the client directory:

```sh
python3 -m unittest discover -s tests -p 'test_export_source.py'
python3 -m unittest discover -s tests -p 'test_bootstrap_sources.py'
python3 export-source.py --check
python3 export-source.py --list
shasum -a 256 -c SOURCE-SHA256.txt
python3 export-source.py ../bedrock-mac-source
```

The destination must not exist. The exporter creates an independent source-only
directory and a SHA-256 inventory. It reads individual paths from `ALLOWED_FILES`
in `export-source.py`; it never traverses ignored directories. Symlinks, missing
files, and binary replacements are rejected. Review and add each new standalone
script, patch, test, and notice to that allowlist before exporting a later version.
Do not replace it with a recursive copy or an extension glob.

The package omits game assets/executables, downloaded archives, source checkouts,
compiled binaries, Wine prefixes and worlds, Keychain data, helper session files,
logs, screenshots, CrossOver, D3DMetal, and Microsoft runtime DLLs. `.gitignore`
alone is not the release boundary. Review the exported source and the inventory
before publishing them to the intended repository.

## Reproduce source preparation

The exported directory includes the patches, exact Cargo lockfile, original
license texts, and a pinned source bootstrap:

```sh
python3 bootstrap-sources.py
python3 bootstrap-sources.py --check
```

The first command fetches the exact Xodus, WineGDK, and DXMT commits listed in
`bootstrap-sources.py`, applies the reference patches before the Bedrock-specific
patches, and installs `patches/Cargo.lock` into Xodus. DXMT is kept unmodified for
the optional native graphics rebuild. It refuses to overwrite any existing
checkout. Use `--project xodus`, `--project winegdk`, or `--project dxmt` for one tree, or
`--destination /an/empty/source-directory` for a separate copy. Fetching needs Git
and network access; `--check` is offline and does not modify the source trees.

The check rebuilds the expected patched files in a temporary directory and compares
them with the checkout. It verifies the pinned base, preserved patch contents,
and Xodus lockfile. It does not certify unrelated local edits, runtime binaries,
or the complete Cargo dependency cache. `standalone-setup.py --build-helper`
copies and builds the current standalone helper example with `--locked`.
`build-helper.sh` builds the earlier CrossOver helper instead. The obsolete separate
`prepare-game.rs` helper is intentionally not exported.

`build-standalone-wine.sh` creates its own build copy of the prepared WineGDK tree
and applies `patches/standalone-wine-dxmt-abi.patch`,
`patches/standalone-wine-idl-list.patch`,
`patches/standalone-wine-storage-linkage.patch`, and
`patches/standalone-wine-user-privileges.patch`, followed by
`patches/standalone-wine-xuser-realms.patch` and
`patches/standalone-wine-xuser-token-refresh.patch` there. These additional patches
include `patches/standalone-wine-xuser-z-device-auth.patch` for PS5 friend joining and
are not applied to the shared baseline checkout by the source bootstrap.
`build-standalone-graphics.sh` retrieves pinned upstream DXMT binaries and notices;
see [the dependency provenance](../THIRD_PARTY.md#standalone-runtime-dependency-provenance).

## Release status and remaining setup

The verified gameplay configuration and its remaining limits are recorded in
[stability notes](STABILITY.md). Source export does not establish that a clean Mac can
complete installation or that a replacement graphics/runtime build passes the
same gameplay checks. Publish those claims only after testing the corresponding
configuration.

The original CrossOver-based scripts assumed an already installed trial, a
configured bottle, the user's downloaded Windows game, and Microsoft's native
threading DLL. They are preserved for reproducibility of that implementation, not
as a claim of complete installation automation. New standalone setup/build paths
must document and verify their own prerequisites and official downloads. No game,
credentials, proprietary runtime, or current user's world is part of this release.

A source release does not grant permission to bundle third-party binaries. Any
future binary release needs its own dependency/notice inventory and matching
corresponding source for the exact components distributed.

## Review and publish source

1. Run the relevant [checks](TESTING.md), regenerate the inventory, and export to
   a new directory whose parent exists. Verify the exported inventory there.
2. Inspect `git diff --check`, the diff, and `git status --short`. Stage only the
   intended source, docs, patches, and inventory; inspect `git diff --cached`
   before committing. Do not rely on `.gitignore` to review publication content.
3. Open a pull request and wait for checks on its final commit. Record live-test
   claims separately from compilation and fixture checks. Merge only within
   the maintainer's requested scope.
4. For a tagged source release, identify the exact commit, its source archive
   checksum, build prerequisites, and known limitations. A normal source PR
   does not require uploading any DMG or local runtime.
5. Do not upload the development DMG as a public installer until the gates in
   [RELEASE.md](RELEASE.md) are satisfied. Once a binary preview is ready, label
   its signing/notarization status and tested platforms explicitly.
