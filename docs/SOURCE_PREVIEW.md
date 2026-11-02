# 0.3.0 source preview 5

**Source-only prerelease.** Tag: `v0.3.0-source.5`. Download the reviewed source
archive from the [release page](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.5).
This updates [source preview 4](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.4)
with the fix for Finder metadata blocking Wine setup. It contains no
app installer or runtime binaries.
The historical local **0.3.0 RC4, build 6** app is a separate artifact.

## Changes since source preview 4

The [reporter for #18](https://github.com/1JRobertson/bedrock-mac/issues/18#issuecomment-6583207507)
confirmed that a Finder `.DS_Store` file was the rejected input. Moving it out of
the source tree made verification pass; the reviewed GDK files were unchanged.

Wine verification now accepts ordinary `.DS_Store` metadata files and leaves them
in place. It still rejects unexpected source files, ignored headers, links named
`.DS_Store`, and changes to reviewed files. The canonical patched source identity
does not change when Finder updates metadata.

The [offline troubleshooting check](DEVELOPMENT.md#wine-source-verification-failures)
does not compile or install anything. Earlier security dependency, authentication
and game-update fixes are included.

The normal startup path remains Windows Bedrock through WineGDK, DXMT and
Rosetta. Unfinished native renderer research is excluded from this release.
The existing opt-in Mullion experiment retains its documented scope and limits.

## Validation and limits

The release page records the final tests, source identity, archive SHA-256 and
clean-export validation. Earlier dependency tests are recorded in
[preview 4](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.4).
Publication does not extend the recorded live results.
No new Wine compilation, game launch or installation was performed for this
release. Existing installed helpers retain their old dependencies until rebuilt
and deliberately replaced. The reporter's M5/macOS 27.2 setup and clean-machine
first run remain unverified.

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
3. Archive the exported directory as `bedrock-mac-0.3.0-source.5.tar.gz`.
   Inspect its exact file inventory and verify its SHA-256. Include the source
   inventory; exclude game files, runtime binaries, worlds and private logs.
4. Create annotated tag `v0.3.0-source.5` at the reviewed commit and a GitHub
   prerelease titled **0.3.0 source preview 5**. Attach the reviewed source archive
   and record its checksum, commit, checks and remaining limits in the release body.
5. Download the published archive and verify its bytes and inventory against the
   reviewed artifact. Preserve earlier previews and their tags as historical releases.

Publishing this source release does not install or update the local game,
change its saves, or qualify a binary app release.
