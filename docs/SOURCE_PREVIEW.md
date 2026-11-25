# 0.3.0 source preview 7

**Source-only prerelease.** Tag: `v0.3.0-source.7`. Get the reviewed archive
from the [release page](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.7).
It contains no app installer or runtime binaries.

## Changes since source preview 6

- Let Homebrew update normally when `Start.command` installs missing build
  tools. Preview 6 disabled automatic updates, which caused outdated Homebrew
  to fail while installing Python on the M1 Air.
- Record the [M1 Air source install and world test](RELEASE.md#m1-air-source-install-and-first-play)
  and the maintainer's [LAN and online Xbox and PS5 play](history/GAMEPLAY.md#repeated-cross-platform-play).

The licensing and Store country fixes from
[source preview 6](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.6)
and the Finder metadata fix from preview 5 are included. For setup failures, see
[build troubleshooting](DEVELOPMENT.md#build-failures).

## Validation and limits

The release page records the final tests, source commit, and archive checksum.
The M1 Air run used source preview 6 after a manual Homebrew update. Setup then
downloaded Minecraft `1.26.6501.0` and reached a local world on macOS 26.6.2.
Preview 7 adds a regression test for the Homebrew change.

Build from [the source instructions](../README.md#start-from-source): Apple
Silicon, macOS 15+, Rosetta, internet and a Microsoft account entitled to
Minecraft for Windows are required. See [compatibility](COMPATIBILITY.md),
[binary release gates](RELEASE.md), and [upstream licenses](../THIRD_PARTY.md).

## Publication procedure

1. Select the reviewed merge commit containing these release notes and the
   maintenance fixes. Record its full SHA and final checks.
2. Verify `SOURCE-SHA256.txt`, export from that exact clean commit with
   `tools/export-source.py`, and run the source tests from the clean export.
3. Archive the exported directory as `bedrock-mac-0.3.0-source.7.tar.gz`.
   Inspect its exact file inventory and verify its SHA-256. Include the source
   inventory; exclude game files, runtime binaries, worlds and private logs.
4. Create annotated tag `v0.3.0-source.7` at the reviewed commit and a GitHub
   prerelease titled **0.3.0 source preview 7**. Attach the reviewed source archive
   and record its checksum, commit, checks and remaining limits in the release body.
5. Download the published archive and verify its bytes and inventory against the
   reviewed artifact. Preserve earlier previews and their tags as historical releases.

Publishing this source release does not install or update the local game,
change its saves, or qualify a binary app release.
