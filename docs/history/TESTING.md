# Test observations — October 2026

Dated source, frame-slab and native skin records retained during reorganization.
Use [current testing instructions](../TESTING.md) to select and run checks.
Counts below belong to their recorded source revision and do not certify a
later app. The [October 21 source audit](AUDIT-2026-10-21.md) records later fixes
and local suite results.

## October 7 source snapshot

An earlier October 7 Python snapshot passed 190 tests. Coverage includes source isolation,
one helper across download/preparation/launch, safe account error messages,
process cancellation, setup-marker corruption, runtime relinking, reduced
download verification, and packaged minimum OS detection. The count is a dated
snapshot, not a requirement to keep it fixed.


## Release-preparation source snapshot, October 7

The coordinator's 23:56 UTC run passed **289 Python tests, zero skips**. The
source export check covered **181 explicitly allowed files**, including only the
exact fingerprint-pinned 539-byte production public verification key as a binary
exception. This does not authorize game payloads, private keys or arbitrary
binaries. The inventory is a dated working-source snapshot, not a release freeze.

These are source/fixture checks. Actual RC3 packaged GPU probes separately passed
in a disposable prefix and preserved all 1,959 payload hashes plus the signature.
Neither result establishes authentication, acquisition, gameplay, saves, M1 or
soak acceptance. See [current readiness](../RELEASE.md).

## Frame allocator installation

The frozen frame-slab installation has offline transaction and launcher checks:

```sh
python3 -m unittest discover -s tests -p 'test_standalone_bedrock_frame_profile.py'
python3 -m unittest discover -s tests -p 'test_standalone.py'
```

These use temporary fake runtimes. Live qualification separately checks the
exact DLL, guarded normal launch path, a copied world's load/movement/save/reload,
new control mappings on repeat launches, and post-exit retirement counters.
Before installing into a regular runtime, exercise stage/restore and verify the
previous DLL/manifest return byte-for-byte. Never replace a mapped runtime.

The October 7 local rollout passed all 32 profile transaction tests, exact
stage/restore/restage on both the copied and regular runtimes, two copied-world
sessions with normal exits, terrain transitions, and save/reload. A controlled
OFF transition drained all 8,535 registered scopes before the second exit.
The regular `client/Launch Standalone.command` then loaded the installed 16 KiB profile
and passed its 16-site game guard. See the graphics notes for scope and counters.

## Native architecture probe

For the standalone M4 native-batch experiment (Apple Silicon, Rosetta and Command
Line Tools required), use a fresh output directory:

```sh
python3 tests/run-m4-native-batch.py --output build/m4-batch-verify
# After quitting Minecraft, with no competing benchmark/build:
python3 tests/run-m4-native-batch.py --output build/m4-batch-timing --benchmark
# Stronger target-specific comparison on an M4-family Mac:
python3 tests/run-m4-native-batch.py --output build/m4-batch-tuned --tuned-m4 --benchmark
```

The default verifies 64 fixtures of 65,536 AABBs against the identical kernel
running in a separate native ARM64 process. The timed mode adds 11 alternating
pairs at each batch size, including semaphore communication. It refuses a
running game and never changes a game process or runtime. Retained synthetic
geometry excludes extraction, updates, draw submission and GPU work; these
results cannot establish a game speedup. See the
[architecture evidence](../research/m4-architecture-results.json).


## October 19 native skin check

Source revision `4470fb5` was tested on an Apple M4 Pro, macOS 15.3.1, with the
owned Bedrock 26.52 game and Wine 11.8. The picker DLL was built from this source;
all **206 contract checks passed under Wine on this Mac**. Its exact DLL and four
prefix registrations verified before gameplay.

The game ran through the resource guard in a fresh, isolated prefix with a
cloned existing development runtime and the existing authorized helper. Optional
performance hooks were not activated. This tests the picker integration in that
local baseline; it does not qualify a reconstructed runtime, packaged RC4, the
reporter's M5 Pro/macOS 27 setup, or a clean Mac.

Observed results:

- **Pass:** Choose New Skin opened the PNG dialog; cancellation returned to
  Dressing Room without a crash.
- **Pass:** the invalid-dimension PNG produced Minecraft's supported-size message.
- **Pass:** a generated 64×64 RGBA PNG showed both model previews and rendered as
  the current skin. Selecting `Skin QA α.png` by browsing also succeeded.
- **Fail:** the current skin reset to the default character after restart,
  including after returning to the main menu and using Minecraft's own exit
  confirmation. Both completed game sessions exited with code 0.
- **Pending:** world import/export regression. The guard stopped the next session
  after app memory exceeded 8 GiB. Its owned game, helper and Wine server exited;
  the regular installation and saves were preserved.

The reported picker crash no longer reproduces on this local baseline. Issue #4
remains open for verification on the reporter's setup; the restart failure has
separate upstream evidence below. World import/export still needs regression QA.

## October 20 skin persistence diagnosis

The same isolated 26.52 baseline was tested sequentially through the resource
guard. A temporary QA-only picker returned the known 64×64 PNG automatically and
logged interface/method names; the maintainer selected the model in Minecraft.
This diagnostic run did not retest the visible file dialog.

- Two imports wrote valid PNGs to the user's `games/com.mojang/custom_skins`
  folder. The selected skin ID was saved in `minecraftpe/options.txt`.
- Import used the modern picker, `StorageFile.GetFileFromPathAsync` and
  `IStorageItem.Path`. No unsupported StorageFile method, GameSave call or
  ApplicationData stub was observed in that trace.
- The game exited with code 0, leaving both PNGs on disk. On relaunch they still
  existed immediately before the game process started, after prefix preparation.
  A file-API trace then observed the game accessing `custom_skins`; both PNGs
  disappeared during startup and the menu showed Alex. The second game also
  exited with code 0. Both owned helpers and Wine servers cleaned up.

This matches Mojang's [MCPE-241720](https://bugs.mojang.com/browse/MCPE-241720),
whose fix is announced in the [26.60.24 Preview notes](https://feedback.minecraft.net/hc/en-us/articles/48940953884173-Minecraft-Beta-Preview-26-60-24).
That is evidence of an upstream game defect consistent with this result, not
verification of a newer game here. Do not enable local GameSave or add speculative
storage APIs to address it. A game containing Mojang's fix needs its own import
and restart test on this runtime. The regular game, saves and helper were not
changed; temporary QA picker diagnostics were removed after testing.
