# 0.3.0 source preview 6

**Source-only prerelease.** Tag: `v0.3.0-source.6`. Get the reviewed archive
from the [release page](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.6).
It contains no app installer or runtime binaries.

## Changes since source preview 5

- Fix a Microsoft content license rejection when an exchanged device ticket
  arrives with a prefix the licensing endpoint does not accept. Only the
  outgoing content license request formats the tickets; Microsoft still
  verifies ownership. The user ticket formatting follows the
  [Nexus Launcher patch](https://github.com/domsvoboda/nexus-launcher/blob/0e2a75a4334d9d8af72e0c452af4010276bc3392/assets/xodus-licensing-jwe.patch).
- The native launcher now saves a two-letter Store country in Settings and
  uses it for sign-in, download and update. The default is CA.
  [PR #24](https://github.com/1JRobertson/bedrock-mac/pull/24) also adds tests
  for interrupted update recovery.

The Finder metadata fix from [preview 5](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.5)
remains included. If an existing checkout reports a mismatched Xodus source
tree after updating, [preserve and refresh that generated checkout](DEVELOPMENT.md#refresh-a-generated-source-checkout-after-a-dependency-update).
The helper must be rebuilt to pick up the fix.

## Validation and limits

The release page records the final tests, source identity and archive checksum.
The licensing failure cleared on a previously tested local helper. This release
does not repeat live Microsoft sign-in, game launch, or update/recovery tests.
The cause of the separate Xbox user-auth failure in [#12](https://github.com/1JRobertson/bedrock-mac/issues/12)
remains unknown, and other Store markets still need live validation.

Build from [the source instructions](../README.md#start-from-source): Apple
Silicon, macOS 15+, Rosetta, internet and a Microsoft account entitled to
Minecraft for Windows are required. See [compatibility](COMPATIBILITY.md),
[binary release gates](RELEASE.md), and [upstream licenses](../THIRD_PARTY.md).

## Publication procedure

1. Select the reviewed merge commit containing these release notes and the
   maintenance fixes. Record its full SHA and final checks.
2. Verify `SOURCE-SHA256.txt`, export from that exact clean commit with
   `tools/export-source.py`, and run the source tests from the clean export.
3. Archive the exported directory as `bedrock-mac-0.3.0-source.6.tar.gz`.
   Inspect its exact file inventory and verify its SHA-256. Include the source
   inventory; exclude game files, runtime binaries, worlds and private logs.
4. Create annotated tag `v0.3.0-source.6` at the reviewed commit and a GitHub
   prerelease titled **0.3.0 source preview 6**. Attach the reviewed source archive
   and record its checksum, commit, checks and remaining limits in the release body.
5. Download the published archive and verify its bytes and inventory against the
   reviewed artifact. Preserve earlier previews and their tags as historical releases.

Publishing this source release does not install or update the local game,
change its saves, or qualify a binary app release.
