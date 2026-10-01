# Preparing a source release

Nothing in these instructions creates a remote repository or publishes files.
Export only the reviewed client source, not the parent server repository or this
entire development directory. Read [THIRD_PARTY.md](../THIRD_PARTY.md) for the
component licenses and credit.

## Validate and export

From the client directory:

```sh
python3 -m unittest discover -s tests -p 'test_export_source.py'
python3 -m unittest discover -s tests -p 'test_bootstrap_sources.py'
python3 export-source.py --check
python3 export-source.py --list
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
before choosing a public repository and explicitly publishing it.

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
or the complete Cargo dependency cache. `build-helper.sh` installs the helper
example sources before its locked Cargo build. The obsolete separate
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
[README.md](../README.md). Source export does not establish that a clean Mac can
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
