# Repository guidance

## Start here

Read [CONTEXT.md](CONTEXT.md) for the architecture and vocabulary, then the guide
for the area you are changing. [README.md](README.md) is the documentation index.
The current product is an open-source preview with a locally tested native Mac
launcher; it is not a released, notarized consumer app.

## Working conventions

- Test apps locally. Do not use ChatGPT Sites or publish a hosted test app.
- Use descriptive branches such as `docs-and-agent-guidance` or
  `fix-setup-retry`. Do not use `Codex/*` or `codex/*` names.
- Inspect `git status` before changes. Preserve unrelated work and generated
  artifacts that an active game or launcher may still use.
- Keep changes focused. Prefer the standalone path; the CrossOver implementation
  is historical and remains available for reference.
- Keep interface copy brief and useful. Show the next action or the current
  task; keep implementation details in logs and documentation.
- Record what was actually tested. Compilation, fixture tests, a live game
  launch, and a clean-Mac installation establish different things.

## Files and process ownership

Packaged app data lives in `~/Library/Application Support/Bedrock for Mac/`.
Source development uses this checkout. Never confuse either with the older
`bottles/Bedrock-Mac` CrossOver prefix. See [the data map](CONTEXT.md#data-and-process-ownership).

- Preserve `game/`, `bottles/`, worlds, and Keychain entries. Repair by preserving
  conflicting files and giving a specific recovery path, not by resetting data.
- Ask the user to quit Minecraft normally before replacing an app/runtime or
  rebuilding its helper. Do not use broad `pkill`, global `wineserver -k`, or
  socket deletion to clear a live session. Cleanup must target an owned process
  or the separate prefix acquired by the operation.
- Do not automate security dialogs, reset Keychain permissions, weaken TLS, or
  disable Gatekeeper to make a test pass. The user handles Microsoft sign-in and
  macOS security prompts. Keep an authorized helper binary stable during a
  repeat-launch test.
- The native Play action owns one helper across download, preparation, and play.
  Preserve that lifecycle when changing setup; a second helper means another
  credential read and can conflict with the active Xbox service.
- Never print, commit, upload, or paste credentials, content keys, signed URLs,
  full service responses, private account identifiers, or unreviewed logs.

## Source and dependency changes

Author changes in tracked source files. `sources/` is generated from pinned
upstream revisions; durable upstream fixes belong in `patches/` and the bootstrap
configuration. `standalone-helper.rs` is copied into the Xodus example directory
by `standalone-setup.py --build-helper`. `build-helper.sh` builds the older helper.

Retain upstream notices, real Microsoft ownership checks, the pinned Cargo
lockfile, and exact download digest checks. Runtime and game payloads never go
into source commits. The unresolved binary release gates are in
[docs/RELEASE.md](docs/RELEASE.md); do not turn an untested assumption into a
supported-platform or security claim.

## Validation and documentation

Use [docs/TESTING.md](docs/TESTING.md) to select checks appropriate to the change.
The common source checks are:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 export-source.py --check
shasum -a 256 -c SOURCE-SHA256.txt
git diff --check
```

After changing an exported file, regenerate `SOURCE-SHA256.txt` using the recipe
in [docs/PUBLISHING.md](docs/PUBLISHING.md#update-the-source-inventory) before
running the checksum check. Add new public source/docs to `ALLOWED_FILES` in
`export-source.py` explicitly; never broaden it to recursively copy directories.
Stage exact files, inspect the staged diff, and keep the working tree free of
accidentally staged runtime data.

Update the relevant user/developer guide with behavior changes and update
`CONTEXT.md` when ownership, paths, interfaces, or architecture change. Keep the
release evidence dated and distinguish outstanding work from completed checks.
Do not rebuild or reinstall the live app for documentation-only changes.

## Issues and reviews

Track work in [GitHub Issues](https://github.com/1JRobertson/bedrock-mac/issues)
and review changes through pull requests. Use the existing bug template. Inspect
the repository's labels before assigning them; no custom triage state machine
is configured by these instructions. Report review findings with a concrete
trigger, impact, and file location. Respect the user's requested scope for
publishing, merging, and release creation.
