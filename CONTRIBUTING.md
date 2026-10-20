# Contributing

Use local development for app testing. Keep game downloads, worlds, credentials,
logs, and compiled dependencies out of commits. The source exporter uses an
explicit allowlist; add each new source file to it.

Read [CONTEXT.md](CONTEXT.md) for the architecture and [AGENTS.md](AGENTS.md) for
repository conventions. The [development guide](docs/DEVELOPMENT.md) documents
the complete local build. Use a descriptive branch; do not use `Codex/*` or
`codex/*` branch names.

## Make a change

1. Check the working tree and preserve unrelated work. Choose the standalone
   component responsible for the behavior; the CrossOver path is historical.
2. Reproduce the problem using a fixture or isolated local test where possible.
   Keep live game and Keychain tests deliberate and let the user handle prompts.
3. Change tracked source. If the fix affects an upstream checkout, preserve it
   as a patch and update the pinned bootstrap/build configuration. Edits only in
   ignored `sources/` or `build/` directories are not reproducible contributions.
4. Run the relevant checks below and update the user/developer documentation.
5. Add new public source/docs to `ALLOWED_FILES` and regenerate the checked-in
   checksum inventory using [this recipe](docs/PUBLISHING.md#update-the-source-inventory).
6. Inspect the staged diff and open a pull request describing the problem,
   resulting behavior, validation, and remaining limits. Verify CI on its final
   commit before merging. A source merge does not publish an app release.

## Checks

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 export-source.py --check
shasum -a 256 -c SOURCE-SHA256.txt
python3 bootstrap-sources.py --check  # after fetching the pinned sources
./build-launcher.sh                 # macOS with Command Line Tools
```

Use [the testing guide](docs/TESTING.md) for which checks a change needs, exact
artifact checks, CI scope, and the manual test matrix. Documentation-only work
does not require rebuilding/replacing the live app.

Default account tests use fake backends and private temporary sockets, without
accessing your Microsoft account or Keychain. After preparing the Xodus sources,
quit Minecraft and let its helper stop, then build/test the current minimal
helper. Bootstrap supplies the helper, XVD module and pinned public key:

```sh
python3 standalone-setup.py --build-helper
cargo +1.98.0 test --release --locked --no-default-features \
  --manifest-path sources/xodus/Cargo.toml -p xodus-cli --example standalone_helper
```

The ignored native Keychain fixture is opt-in. It creates and removes only its
own random test entry. It does not establish how many prompts a user's existing
account will show. Select live account/package fixtures deliberately, following
[the opt-in test boundaries](docs/TESTING.md#native-app-and-helper); never add
`--include-ignored` to routine checks. Do not automate security-dialog clicks.

After building the standalone runtime, `bash tests/run-xuser-tests.sh` runs the
68 account-claim, Realms-routing, and token-refresh checks. Live game, Keychain, fresh-account,
and clean-Mac testing are separate from these offline checks.

## Bug reports

Include macOS version, Mac model/chip/memory, app/source version (and DMG hash
when available), Minecraft version, the last setup stage, and what you expected. State whether this is a fresh install, retry, or app update.
Use the GitHub issue template. Do not post account tokens, passwords, signed
URLs, email addresses, entire Keychain exports, or full unreviewed logs.

Preserve existing worlds and credentials in fixes. New tests should reproduce
the failure at the real boundary (for example, download-to-play ownership of the
same helper), rather than simply repeat implementation details.
