# 0.3.0 source preview 9

Get the source archive and
optional [prebuilt Wine tools](DEVELOPMENT.md#reuse-prebuilt-wine-tools) from
the [Preview 9 release](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.9).

## Changes since source preview 8

- Download supported Minecraft packages in four parts, verify the complete
  package, and unpack game files in larger batches.
- Show verification, unpacking progress, and game profile setup after the
  transfer finishes. The launcher explains the wait for the first game window.

The release includes the same verified Wine tools and corresponding source
as [preview 8](https://github.com/1JRobertson/bedrock-mac/releases/tag/v0.3.0-source.8).
The optional archive skips compiling Wine and its native dependencies.

## M1 Air testing

In two private packaged tests on the same M1 Air, time from the start of setup
to Minecraft process launch went from **5m 43s to 4m 43s**. The maintainer
confirmed the main menu appeared. The [M1 test record](RELEASE.md#m1-air-packaged-install-timing)
describes the timing and the separate source install that reached a local world.

Follow the [source setup instructions](../README.md#start-from-source). Setup
requires Apple Silicon, macOS 15 or later, Rosetta, internet, and a Microsoft
account that owns Minecraft for Windows. See [compatibility](COMPATIBILITY.md),
[binary release gates](RELEASE.md), and [upstream licenses](../THIRD_PARTY.md).
For setup failures, see [build troubleshooting](DEVELOPMENT.md#build-failures).

## Publication procedure

1. Select the reviewed merge commit containing these release notes and the
   maintenance fixes. Record its full SHA and final checks.
2. Verify `SOURCE-SHA256.txt`, export from that exact clean commit with
   `tools/export-source.py`, and run the source tests from the clean export.
3. Archive the exported directory as `bedrock-mac-0.3.0-source.9.tar.gz`.
   Inspect its exact file inventory and verify its SHA-256. Include the source
   inventory; exclude game files, runtime binaries, worlds and private logs.
4. Create annotated tag `v0.3.0-source.9` at the reviewed commit and a GitHub
   prerelease titled **0.3.0 source preview 9**. Attach the source and checksum,
   the verified Wine tools and their corresponding source and checksums.
   Record the commit, tests, and archive checksums in the release body.
5. Download the published archive and verify its bytes and inventory against the
   reviewed artifact. Preserve earlier previews and their tags as historical releases.

Publishing this source release does not install or update the local game,
change its saves, or qualify a binary app release.
