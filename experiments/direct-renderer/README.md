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
is included along with an isolated Wine/worker runner.
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

## Build and run

Use Apple Silicon, macOS 15 or later, Rosetta, Xcode command-line tools,
Python 3.9+, Meson, Ninja, llvm-mingw with the `x86_64-w64-mingw32-*` tools
on PATH, and Pillow in the Python environment used for the fixture.
Use the project's standalone WineGDK build with the original DXMT 0.80
graphics modules. See [development setup](../../docs/DEVELOPMENT.md).

From the repository root, prepare the pinned DXMT checkout:

```sh
git clone https://github.com/3Shain/dxmt.git build/direct-dxmt
git -C build/direct-dxmt checkout 589adb780354b461645b29999cefaf533594ee99
git -C build/direct-dxmt submodule update --init --recursive
```

Set `RESEARCH_WINE` to the absolute path of the compatible Wine installation.
Build the two variants into new output directories:

```sh
for mode in direct control; do
  python3 tools/qa_resource_guard.py --log "$PWD/build/$mode-build.log" -- \
    python3 experiments/direct-renderer/build_renderer.py "$mode" \
    --dxmt build/direct-dxmt --wine "$RESEARCH_WINE" --output "build/$mode" || break
done
```

The build checks the pinned DXMT inputs, then builds the x86-64 bridge, the
modified Windows DLLs, and the ARM64 worker. [The control patch](faster-control.patch)
preserves the source differences for the faster native renderer. It has its own
[hashes](faster-control.json) and does not ship the historical binaries.
[DXMT source metadata](dxmt-source.json) pins the direct variant.

Run the same D3D fixture on both builds with one command:

```sh
python3 tools/qa_resource_guard.py --log "$PWD/build/renderer-benchmark.log" -- \
  python3 experiments/direct-renderer/benchmark.py --wine "$RESEARCH_WINE" \
  --direct build/direct --control build/control --output build/renderer-benchmark
```

The runner clones Wine and creates a fresh prefix for each mode, checks the
loaded modules, and records image checks and gate-to-readback timings in
`results.json`. These timings include fixture synchronization and readback;
they are not gameplay FPS. The fixture needs no game or sign-in.

For gameplay, provision a **separate disposable standalone data root** under
this checkout's `build/`, with an owned, prepared game in `game/`, WineGDK and
DXMT under `runtime/standalone/`, the verified threading component under
`runtime/`, and the standalone helper under `sources/xodus/target/release/examples/`.
Use a fresh root for each variant, without an existing Wine prefix. The research
launcher stages its modules only there and calls the normal standalone license
flow. Choose your Store market and handle any sign-in prompt locally.

```sh
python3 tools/qa_resource_guard.py --log "$PWD/build/renderer-game.log" -- \
  python3 experiments/direct-renderer/launch_game.py \
  --home build/disposable-direct --renderer build/direct --market CA
```

For comparison, use the same game build, world seed, view distance, frame
settings and camera path with `--renderer build/control` in a second disposable
root. Quit normally to collect native presentation samples under `renderer-run/`.
This research launcher is supplied as a starting point. It has not been
accepted in licensed gameplay, and the historical overlay, automated camera
script and exact FPS measurement workflow are not reproduced here.

Known limitations: rendering must be owned from startup; late activation cannot
recover already GPU-rendered atlases from CPU initialization. Some commands and
texture shapes are rejected. Startup history is bounded at 256 MiB and an
individual owned buffer at 32 MiB. A source/drawable size mismatch rejected one
startup; an unchanged retry passed. This is not a finished general renderer.

## Publication checks and licensing

Both source variants compiled and linked locally. The direct build passed all
eight GPU image/readback checks through the new fixture runner. The control
fixture run was stopped before a result, and the licensed launcher was not run.
The published historical gameplay figures were not remeasured.

Original project research source is GPLv3 under the repository [license](../../LICENSE).
DXMT-derived changes retain its MIT license and existing upstream notices; see
[DXMT's license](../../LICENSES/dxmt-LICENSE.txt) and [third-party notices](../../THIRD_PARTY.md).
No binaries, game assets, screenshots, private logs or private build receipts
are included. The normal source release is unchanged; this is a separate
research branch. AI assistance: OpenAI Codex; exact model versions for the
historical implementation and this packaging session are not available.
