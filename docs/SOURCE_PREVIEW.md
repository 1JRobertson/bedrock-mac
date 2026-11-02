# 0.3.0 source preview 3

**Source-only prerelease.** Tag: `v0.3.0-source.3`. Download the reviewed source
archive from the [release page](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.3).
This updates [source preview 2](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.2)
with clearer Wine setup diagnostics. It contains no app installer or runtime binaries.
The historical local **0.3.0 RC4, build 6** app is a separate artifact.

## Changes since source preview 2

[PR #19](https://github.com/1JRobertson/bedrock-mac/pull/19) makes **Unexpected
untracked or ignored Wine source inputs** identify the files that stopped setup.
The error shows the total count and up to five bounded, escaped relative paths.
The [offline troubleshooting check](DEVELOPMENT.md#wine-source-verification-failures)
does not compile or install anything.

The GDK files listed in [issue #18](https://github.com/1JRobertson/bedrock-mac/issues/18)
are already supplied by reviewed patches and pass verification in a fresh
reconstruction. Their ordinary Git status is expected. The reporter's original
failure is still under investigation; this release helps identify its cause.
Source acceptance rules are unchanged. The authentication and game-update fixes
from preview 2 are included.

The normal startup path remains Windows Bedrock through WineGDK, DXMT and
Rosetta. Unfinished native renderer research is excluded from this release.
The existing opt-in Mullion experiment retains its documented scope and limits.

## Validation and limits

The maintenance source passed **386 Python tests**, all **281 source inventory
hashes**, export boundary checks and release-profile verification. A fresh pinned
Wine checkout with all shipped patches passes both verifier versions with the
same expected tree. An extra header is rejected with its filename; the real Git
index is preserved. Earlier authentication/helper checks remain recorded in the
[preview 2 release](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.2).

The release page records the final tagged commit, source archive SHA-256 and
clean-export validation. Publication does not extend the recorded live results.
No new Wine compilation, game launch or installation was performed for this
release. The reporter's M5/macOS 27.2 setup and clean-machine first run remain
unverified.

Build from [the source instructions](../README.md#start-from-source): Apple
Silicon, macOS 15+, Rosetta, internet and a Microsoft account entitled to
Minecraft for Windows are required. A clean-machine first run and a distributable
app remain unqualified. See [compatibility](COMPATIBILITY.md) and
[binary release gates](RELEASE.md). Original code is GPLv3;
[upstream licenses and notices](../THIRD_PARTY.md) remain applicable.

## Publication procedure

1. Select the reviewed merge commit containing these release notes and the
   maintenance fixes. Record its full SHA and final checks.
2. Verify `SOURCE-SHA256.txt`, export from that exact clean commit with
   `tools/export-source.py`, and run the source tests from the clean export.
3. Archive the exported directory as `bedrock-mac-0.3.0-source.3.tar.gz`.
   Inspect its exact file inventory and verify its SHA-256. Include the source
   inventory; exclude game files, runtime binaries, worlds and private logs.
4. Create annotated tag `v0.3.0-source.3` at the reviewed commit and a GitHub
   prerelease titled **0.3.0 source preview 3**. Attach the reviewed source archive
   and record its checksum, commit, checks and remaining limits in the release body.
5. Download the published archive and verify its bytes and inventory against the
   reviewed artifact. Preserve previews 1 and 2 and their tags as historical releases.

Publishing this source release does not install or update the local game,
change its saves, or qualify a binary app release.
