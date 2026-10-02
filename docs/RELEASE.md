# Release readiness

This is a source preview. A local development DMG exists, but it is not a signed,
notarized, or clean-Mac-verified public binary release. Apple Developer membership
is not required to publish the source or an explicitly unsigned preview.

## Verified behavior

- Owned Windows package downloaded and prepared on the development Mac.
- Native launcher started Minecraft; the user confirmed **Sign in now** worked
  with the existing Microsoft session on October 2, 2026.
- Earlier standalone runtime testing reached local gameplay, a featured-server
  lobby, and the joined-Realm list. Entry into an active Realm and PS5 friend
  sessions have not been verified.
- Live retest on October 2: an unchanged app launched after one Keychain prompt
  when the user chose **Allow** (one-time access). Remembered authorization via
  **Always Allow** is being checked separately; it must not be inferred from the
  credential-cache tests.
- Offline tests cover one account helper across download and launch, failed
  setup cleanup, cancellation with a real child process, bounded sign-in waits,
  damaged setup records, progress parsing, and source export boundaries.
- Helper tests cover the single credential read, denied reads, failed writes,
  account switching, package path validation, and CDN URL policy.

Automated tests use fixtures; they do not prove a clean-machine sign-in or a
particular number of macOS security prompts.

## Before publishing a binary preview

- Inventory the bundled Python/PyInstaller, Rust, Wine dependency, and graphics
  components. Include their notices and matching source/build materials.
  The existing Wine dependency archive has not had a complete redistribution
  inventory; see [THIRD_PARTY.md](../THIRD_PARTY.md).
- Complete authentication/integrity verification for all game package sections.
  The current catalog may return Microsoft's HTTP CDN endpoints; existing
  segment checks do not authenticate every unencrypted section. Account and
  license requests use certificate-verified HTTPS.
- Test a clean Mac: downloaded DMG, Applications install, Rosetta absent/present,
  fresh owner sign-in, declined Keychain access, cancellation, retry, successful
  launch, world save/reopen, sign-out, and replacement with an updated app.
- Record the actual minimum macOS version of **all** bundled Mach-O binaries.
  Current locally built Wine/Python components require macOS 26. Changing the
  front end's deployment target or just swapping Python is insufficient.
- Verify quit/reopen and upgrade Keychain behavior. Ad-hoc rebuilds can change the
  helper's signing identity; no zero-prompt update claim is made.
- Include checksums and tested limitations in release notes. Use a GitHub
  prerelease for unsigned previews; signing/notarization is a separate step
  toward a normal public Mac distribution.

## Local validation

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 bootstrap-sources.py --check
python3 export-source.py --check
./build-launcher.sh
cargo +1.98.0 test --release --locked --manifest-path sources/xodus/Cargo.toml \
  -p xodus-cli --example standalone_helper
bash tests/run-xuser-tests.sh
```

`package-launcher.py` verifies the final bundle signature and records SHA-256
hashes of bundled resource files. `build-dmg.py` verifies the image after creating
it. These integrity checks do not replace notarization or gameplay testing.
