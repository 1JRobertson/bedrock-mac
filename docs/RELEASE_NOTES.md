# Release notes — draft preview

**Unreleased local test artifact: 0.3.0 RC4, build 6.** Requires macOS 15.0+,
Apple Silicon and Rosetta. Ad-hoc signed; not notarized. Public download is pending.

DMG SHA-256: `2843d513f425c0eb17669c3fa73356e91244b77349863a07cbe8384583201fb5`.

Source-snapshot/resource checks and mounted-DMG worker/load checks passed.
Earlier RC3 packaged GPU probes passed with its 1,959 resources intact;
that historical result is not an RC4 live-game test.
A separate exact-copy audit matched all 908 selected notice files; full source
and build-provenance clearance remains separate.
Earlier RC3 native **Cancel** at the initial Keychain wait passed: the helper
exited, no socket remained, no prefix was created or game started, and payload key hashes
were unchanged. Retry, authentication and gameplay were not tested by that cancellation case.
A later RC3 session was user-confirmed functioning and returned normally, using
a copied owned payload. Save/reopen and soak are still unverified.
See [release readiness](RELEASE.md).

## Included source behavior

- Native Mac launcher with Install & Play, setup progress, Cancel/Continue,
  retry, local logs, and Microsoft sign-out. Existing games needing runtime
  preparation show **Finish setup / Continue**.
- Microsoft account ownership checks, game acquisition, and one account helper
  retained through preparation and gameplay.
- Windows Bedrock through WineGDK, Rosetta, and Direct3D 11 translation via DXMT.
- Quit/window handling uses one asynchronous sheet: closing/reopening the window
  keeps the worker alive; repeated Quit requests cannot stack sheets. The exact
  code passed native synthetic fixtures; real RC4 game-session validation is pending.
- **Update Minecraft…** downloads separately, retains the previous game/prefix,
  and recovers interrupted activation. Live update/recovery validation is pending.
- Game files and worlds stored outside the app; manual app replacement reuses
  existing data by design. Fresh-machine update/restore qualification is pending.

These describe the source implementation, not a completed release-candidate
acceptance test. The reviewed candidate inputs retain shared buffers, packed
constants, input-layout reuse, 48-byte heap reuse, and display/ColorSync lifetime
fixes. They exclude refmove, frame slab, pacing, metrics HUD, exact-current,
recurrence observers, and constant-buffer borrowing. RC4 package hashes are
recorded in the readiness page;
gameplay still needs verification. Native ARM game execution is not included.

## Known limits

**RC4 remains a local test candidate.** It contains the helper that passed
verified acquisition outside the app. Native first-run, update, gameplay and
clean-M1 qualification remain open in the [release record](RELEASE.md).


Apple Silicon and Rosetta are required. Internet/account verification is required
on Play. There is no automatic app or Minecraft updater. Existing installations
reuse their game, which can become incompatible with a friend's updated version.
Use **Update Minecraft…** when a newer version is needed; do not delete worlds
to resolve a version mismatch. See the
[user guide](USER_GUIDE.md#your-files-backups-and-updates).

Clean M1 installation, current-candidate multiplayer/rejoin, extended stability,
backup restore, and changed-helper Keychain prompts are not yet qualified.
**Dressing Room → Choose New Skin** has a
[reported crash (#4)](https://github.com/1JRobertson/bedrock-mac/issues/4) at
`99fc9aa`; native verification of a fix remains pending.
Active Realm entry and complete Marketplace/controller support are unverified.
Developer ID/notarization and acquisition/distribution gates remain visible in
the [readiness table](RELEASE.md). No cumulative FPS, power, native-ARM-game,
zero-prompt-upgrade, or issue-free claim is made.
