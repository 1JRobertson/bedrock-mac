# 0.3.0 source preview 1

**Prepared, not published.** Proposed tag: `v0.3.0-source.1`, a GitHub
prerelease containing source only. There is no binary installer or notarized app.
This version is separate from the historical local **0.3.0 RC4, build 6** artifact.

## Release notes

This preview provides the native macOS launcher and source setup for an owned
Minecraft for Windows game on Apple Silicon, using WineGDK, DXMT and Rosetta.
The launcher handles setup, sign-in and recovery, then opens vanilla Minecraft.

- Source includes Microsoft ownership checks and verified game acquisition,
  a single account helper through preparation/play, file-picker compatibility,
  and manual **Update Minecraft…** with journaled recovery.
- Includes [PR #10](https://github.com/1JRobertson/bedrock-mac/pull/10): queue
  WinHTTP writes issued inside status callbacks to avoid duplicate PlayFab
  request bodies. The isolated native regression reproduced the failure before
  the fix and passed after it; [compiled-DLL game acceptance remains open](history/PARTY-WINHTTP-2026-10-25.md#validation-and-limits).
- Adds concise status, contribution tasks, a PR template, roadmap and original
  repository preview artwork. These presentation changes do not rebuild a runtime.

Build from [the source instructions](../README.md#start-from-source): Apple
Silicon, macOS 15+, Rosetta, internet and a Microsoft account entitled to
Minecraft for Windows are required. Source builds need the documented toolchain
and compatible build path. Build duration and minimum build-space needs have not
been measured; a clean-machine first run is not yet qualified.

Historical M4 Pro gameplay and a less detailed M1 Air report do not qualify this
source snapshot or a newly packaged app. Current-candidate save/restore,
multiplayer/rejoin, live update/recovery and extended stability remain open.
No supported offline launch or automatic updater is included. Mullion ray
tracing is opt-in research, not general Direct3D 12 support; native ARM game
execution is not included. See [compatibility](COMPATIBILITY.md) and
[binary release gates](RELEASE.md). Original code is GPLv3; [upstream licenses
and notices](../THIRD_PARTY.md) remain applicable.

## Publication plan

1. Merge the presentation PR only after review and final checks. The reviewed
   runtime baseline is `8d2c82ea26fce3c699998648dd895f257e20d0a8` (merged PR #10);
   tag the eventual presentation merge commit, not that earlier baseline.
2. Record the full target commit and checks on that exact revision. Regenerate
   and verify `SOURCE-SHA256.txt`; run the [source export checks](PUBLISHING.md#validate-and-export)
   and tests from a clean export. Review the archive contents.
3. Export that commit with `tools/export-source.py` into a new directory named
   `bedrock-mac-0.3.0-source.1`. Archive it as
   `bedrock-mac-0.3.0-source.1.tar.gz`, including its source inventory. Record the
   archive SHA-256 in the release body, along with the full commit and actual
   checks/skips. Never substitute a development-directory archive.
4. Create the annotated tag `v0.3.0-source.1` at that commit and a GitHub
   **prerelease**, titled **0.3.0 source preview 1**. Use the release notes above,
   plus the commit/checksum/checks receipt. Attach only the reviewed source archive;
   no DMG, game, runtime binaries, worlds, credentials or private logs.

This PR prepares the notes and tag plan. It does not publish a release or
authorize its own merge. Publication waits for a matching merged revision;
no release date is promised.
