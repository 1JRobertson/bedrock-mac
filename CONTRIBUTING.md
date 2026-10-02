# Contributing

Use local development for app testing. Keep game downloads, worlds, credentials,
logs, and compiled dependencies out of commits. The source exporter uses an
explicit allowlist; add each new source file to it.

## Checks

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 export-source.py --check
python3 bootstrap-sources.py --check  # after fetching the pinned sources
./build-launcher.sh                 # macOS with Command Line Tools
```

Account tests use fake backends and private temporary sockets. They never access
your Microsoft account or Keychain. After preparing the Xodus sources and helper
example, run its credential-cache and URL-policy tests:

```sh
cargo +1.98.0 test --release --locked --manifest-path sources/xodus/Cargo.toml \
  -p xodus-cli --example standalone_helper
```

The ignored native Keychain fixture is opt-in. It creates and removes only its
own random test entry. It does not establish how many prompts a user's existing
account will show. Do not automate clicks on security dialogs.

After building the standalone runtime, `bash tests/run-xuser-tests.sh` runs the
50 account-claim and Realms-routing checks. Live game, Keychain, fresh-account,
and clean-Mac testing are separate from these offline checks.

## Bug reports

Include macOS version, Mac chip, app/source version, the last setup stage, and
what you expected. State whether this is a fresh install, retry, or app update.
Use the GitHub issue template. Do not post account tokens, passwords, signed
URLs, email addresses, entire Keychain exports, or full unreviewed logs.

Preserve existing worlds and credentials in fixes. New tests should reproduce
the failure at the real boundary (for example, download-to-play ownership of the
same helper), rather than simply repeat implementation details.
