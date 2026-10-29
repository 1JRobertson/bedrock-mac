# 0.3.0 source preview 2

**Source-only prerelease.** Tag: `v0.3.0-source.2`. Download the reviewed source
archive from the [release page](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.2).
This updates the October 26 [source preview 1](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.1)
with the merged maintenance fixes. It contains no app installer or runtime binaries.
The historical local **0.3.0 RC4, build 6** app is a separate artifact.

## Changes since source preview 1

- [PR #13](https://github.com/1JRobertson/bedrock-mac/pull/13) returns bounded,
  sanitized Xbox authentication diagnostics instead of panicking on HTTP errors.
- [PR #15](https://github.com/1JRobertson/bedrock-mac/pull/15) uses the
  client-bound Xbox Token Broker ticket for game acquisition, selects responses
  by type and retains validated STS renewal in the same helper session. Final
  executable preparation writes the logical file length while staging preserves
  full cipher blocks. The review also fixed the new debug test fixture.
- [PR #14](https://github.com/1JRobertson/bedrock-mac/pull/14) makes recorded
  local checks the default merge evidence and adds a clean-install test recipe.
  Hosted checks remain available through manual dispatch.
- [PR #16](https://github.com/1JRobertson/bedrock-mac/pull/16) encourages
  AI-assisted contributions and equally welcomes handwritten code. New PRs
  identify models used and known versions, or state `None`/`Unknown` as applicable.

The normal startup path remains Windows Bedrock through WineGDK, DXMT and
Rosetta. Unfinished native renderer research is excluded from this release.
The existing opt-in Mullion experiment retains its documented scope and limits.

## Validation and limits

The integrated maintenance source passed **384 Python tests**, all **281 source
inventory hashes**, export boundary checks and **162 pinned Xodus source/input
checks**. Targeted Rust validation passed **19 Xbox tests, 2 preparation tests
and 38 helper tests**; **7 existing opt-in helper tests were ignored**. Exact
source revisions and review receipts are recorded in the linked PRs.

The release page records the final tagged commit, source archive SHA-256 and
clean-export validation. Publication does not extend the recorded live results.
An earlier diagnostic candidate completed an authorized 26.52-to-26.60 update;
the final release's live acquisition, startup and multiplayer remain unverified.

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
3. Archive the exported directory as `bedrock-mac-0.3.0-source.2.tar.gz`.
   Inspect its exact file inventory and verify its SHA-256. Include the source
   inventory; exclude game files, runtime binaries, worlds and private logs.
4. Create annotated tag `v0.3.0-source.2` at the reviewed commit and a GitHub
   prerelease titled **0.3.0 source preview 2**. Attach the reviewed source archive
   and record its checksum, commit, checks and remaining limits in the release body.
5. Download the published archive and verify its bytes and inventory against the
   reviewed artifact. Preserve preview 1 and its tag as historical releases.

Publishing this source release does not install or update the local game,
change its saves, or qualify a binary app release.
