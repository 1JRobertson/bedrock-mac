# Native Metal renderer: contributor handoff

**Working gameplay research, severe performance regression, help welcome.**
This is the direct-command candidate from local checkpoint `3475aa1`, made
available as source for further work. It is not the renderer used by the normal
launcher. The private checkpoint hash identifies provenance; that development
history is not required to read this snapshot and is not published here.

The goal was to move graphics submission out of the translated Windows process
into an ARM64 Metal worker. The game and DXMT front end still run under Rosetta.
The previous native renderer captured passes and reconstructed their resources.
This candidate instead forwards ordered commands and owned resource updates.
It runs from game startup, including menus, world loading and camera movement.
It has not demonstrated a speed advantage over either the old native renderer
or DXMT. DXMT was not rebenchmarked in the final comparison.

## Actual result

| Renderer | Still | Turning |
| --- | ---: | ---: |
| Previous native renderer, following control | 49.18 FPS | 46.94 FPS |
| Direct commands, final candidate | 13.05 FPS | 12.78 FPS |

[Results](results.json) include the earlier control and intermediate candidates.
All used the same disposable world seed, raw view setting 128, 1280×772 output,
uncapped source, source vsync off, native vsync on, 20-second warmup, 12-second
stationary sample, then 512 relative mouse events over four seconds.
FPS counts positive native presentation callbacks; it is not F3 or proof of
unique physical refreshes. Terrain, HUD, held item and turning were visually
checked, but this was not broad gameplay or pixel-exact acceptance.

The final run processed 8,448 native payloads and 179,650 draws with the old
capture and reconstruction counters both zero. Eight D3D/Wine → native Metal
fixture images and readbacks passed before that run. The fixture covers initial
textures/indices, deferred and staging writes, repeated NO_OVERWRITE, depth
initialization, and packed upload slices. Its [source](fixtures/direct_d3d.cpp)
is included; the coordinated Wine/worker fixture runner is not yet portable.
These are historical results from November 3, 2026, not fresh gameplay tests of
this publication branch.

## Where to start

| Code | Purpose |
| --- | --- |
| [Producer](source/live_command_source.inc) | Ordered commands, bindings, resource events and JSON/blob packing |
| [Startup journal](source/live_startup_journal.inc) | Known CPU initialization, copies and generation retirement |
| [Native interpreter](native-source/live_command_native.inc) | Persistent Metal resources, upload execution and draw validation |
| [DXMT patch](dxmt-direct-renderer.patch) | Complete 41-file delta against public DXMT 0.80, including startup and writer hooks |
| [Native build](build_native.py) | Standalone ARM64 worker build, without private object-file dependencies |

`source/` and `native-source/` preserve the producer and worker component
snapshots. They deliberately contain some old-path support code and different
versions of shared filenames. Do not flatten these directories. The direct mode
branches before per-pass capture and old replay reconstruction; leaving their
source present does not mean the tested mode used them. It still decodes a wire
protocol and constructs Metal bindings. Real completion remains necessary for
readbacks, query readiness and retirement.

The performance regression is concrete: about 7.47 MiB/frame versus 2.52 for the
earlier control. Final native decode and execution averaged about 18.0 and
26.5 ms/frame, versus 9.7 and 14.3. One sampled heavy source pass spent 33.1 ms
packaging uploads and JSON. That is a sample, not a per-frame average or pure
JSON cost; stages can overlap and should not be summed as exact frame latency.

Promising work, without any guarantee of recovering the gap:

1. Replace per-pass dictionaries/JSON and repeated descriptors with compact
   command records. Preserve ordered semantics and explicit rejection.
2. Reduce full-range CPU uploads; retain native allocations safely across
   generations. CPU bytes being unchanged does not prove GPU contents are
   unchanged. Respect intervening GPU writes and in-flight lifetimes.
3. Profile and benchmark the whole game path, using matched settings and turns.
   A faster serialization microbenchmark alone is not a gameplay win.

## What can be reproduced now

On an Apple Silicon Mac with Xcode command-line tools and the required Metal
SDK, from the repository root, build the native worker into a new directory:

```sh
python3 tools/qa_resource_guard.py --log "$PWD/build/direct-native-guard.log" -- \
  python3 experiments/direct-renderer/build_native.py --output build/direct-native
```

This compiles and links only. It does not sign, install, launch, authenticate,
download Minecraft or touch saves. The worker requires a compatible producer;
running the executable alone is not a game launch procedure.

Reconstruct the modified DXMT sources in a separate checkout:

```sh
git clone https://github.com/3Shain/dxmt.git build/direct-dxmt
git -C build/direct-dxmt checkout 589adb780354b461645b29999cefaf533594ee99
git -C build/direct-dxmt submodule update --init --recursive
git -C build/direct-dxmt apply ../../experiments/direct-renderer/dxmt-direct-renderer.patch
```

[dxmt-source.json](dxmt-source.json) records the exact base and all changed-file
hashes. The patch applies to that public revision without unpublished earlier
patches. The normal launcher remains on its existing graphics build.

**The end-to-end game build/launch is not yet reproducible from this handoff.**
The old local harness reused generated bridge objects, pinned Wine components,
shader-service setup, IPC endpoints, and a disposable licensed game session.
This snapshot supplies the component code and DXMT delta, but does not claim a
replacement for that orchestration. Porting the bridge build and fixture/session
runner is a concrete first contribution. Do not guess environment flags and
install the result over a working client. Real Microsoft ownership/sign-in is
still required; there is no bundled game, account data or authentication bypass.

Known limitations: rendering must be owned from startup; late activation cannot
recover already GPU-rendered atlases from CPU initialization. Some commands and
texture shapes are rejected. Startup history is bounded at 256 MiB and an
individual owned buffer at 32 MiB. A source/drawable size mismatch rejected one
startup; an unchanged retry passed. This is not a finished general renderer.

## Publication checks and licensing

For this handoff, the native worker was freshly compiled and linked from these
files. The DXMT patch was applied to the pinned public revision and all 41
resulting hashes matched the measured candidate. Export and source inventory
checks are recorded in the draft PR. No new gameplay or DXMT benchmark was run.

Original project research source is GPLv3 under the repository [license](../../LICENSE).
DXMT-derived changes retain its MIT license and existing upstream notices; see
[DXMT's license](../../LICENSES/dxmt-LICENSE.txt) and [third-party notices](../../THIRD_PARTY.md).
No binaries, game assets, screenshots, private logs or private build receipts
are included. The normal source release is unchanged; this is a separate
research branch. AI assistance: OpenAI Codex; exact model versions for the
historical implementation and this packaging session are not available.
