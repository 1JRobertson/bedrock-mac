# Release readiness

This is a source preview. A local development DMG exists, but it is not a signed,
notarized, or clean-Mac-verified public binary release. Apple Developer membership
is not required to publish the source or an explicitly unsigned preview.

Status snapshot: October 2, 2026. The native launcher source was merged in
[PR #1](https://github.com/1JRobertson/bedrock-mac/pull/1), merge commit `0205d2a`.
That merge did not publish a binary. Use [TESTING.md](TESTING.md) for the manual
test matrix and artifact checks; use [PUBLISHING.md](PUBLISHING.md) for source
inventories and exports.

## Verified behavior

- Owned Windows package downloaded and prepared on the development Mac.
- Native launcher started Minecraft; the user confirmed **Sign in now** worked
  with the existing Microsoft session on October 2, 2026.
- Earlier standalone runtime testing reached local gameplay, a featured-server
  lobby, and the joined-Realm list. Xbox multiplayer and PS5 friend-world entry were confirmed on the September 30
  stability build; see [the dated evidence](STABILITY.md). Entry into an active
  Realm and gameplay with the combined native-launcher build remain unverified.
- Live retest on October 2: **Allow** produced one prompt on the next launch.
  The user then chose **Always Allow**, quit Minecraft, and launched the unchanged
  build again: **no Keychain prompt**. This verifies remembered access for this
  build, not authorization across a changed helper signature.
- The final local app was installed in Applications. Play started Minecraft
  using the existing game and saved account; the launcher reached its running
  state. This was an existing installation on the development Mac, not a clean
  account or downloaded-app Gatekeeper test.
- Offline tests cover one account helper across download and launch, failed
  setup cleanup, cancellation with a real child process, bounded sign-in waits,
  damaged setup records, progress parsing, and source export boundaries.
- Helper tests cover the single credential read, denied reads, failed writes,
  account switching, package path validation, and CDN URL policy.

Automated tests use fixtures; they do not prove a clean-machine sign-in or a
particular number of macOS security prompts.

## Current support limits

| Area | Status |
| --- | --- |
| Local packaged app | Apple Silicon, Rosetta, macOS 26 minimum for the assembled components |
| Swift / pinned DXMT targets | macOS 15; this does not establish support for the complete bundle |
| Game version observed | Windows Bedrock 1.26.5203.0; Microsoft's catalog selects the version for a new download |
| Distribution | Public source; local ad-hoc signed app/DMG; no public notarized installer |
| Updates | Manual app replacement; existing game reused; no automatic game updater |
| Offline launch / native market selector | Not implemented; native setup uses `CA`, CLI accepts a market argument |
| Gameplay evidence | Local gameplay, featured-server lobby, joined-Realm listing observed; active Realm entry and PS5 friend sessions unverified |
| Saves | Existing data preserved by installation/update paths; clean-Mac world save/reopen and restore scenarios remain to be verified |

Earlier graphics notes record a different historical host/OS. They do not lower
the current bundle's inspected macOS requirement. No Intel-Mac, older-macOS,
all-game-versions, Marketplace-completeness, or zero-prompt-update support claim
is made.

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

See [TESTING.md](TESTING.md) for prerequisites and live-test boundaries. Close
the game/helper before rebuilding source components. After bootstrap and
preparing the current helper example, the core checks are:

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
