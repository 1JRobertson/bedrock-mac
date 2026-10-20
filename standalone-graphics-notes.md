# Standalone graphics

These are component notes and historical test observations. The current complete
app's minimum OS and verified behavior are in [release status](docs/RELEASE.md);
the component's deployment target does not establish support for the whole app.

The October 5–6 performance entries below describe the local source-development
runtime. References to installed profiles or the normal launcher refer to that
runtime, not a packaged release. The frame-pacing and HUD builders require the
prepared local build directories named in their scripts. Their build artifacts,
staging scripts, private diagnostic captures, and runtime markers are excluded
from source export. The HUD was rolled back after a startup crash and remains
disabled pending diagnosis; see the final entry.

`build-standalone-graphics.sh` stages the upstream DXMT v0.80 release into
`runtime/standalone/dxmt/`. It checks the pinned SHA-256 before extracting only
the four x64 graphics DLLs and `winemetal.so`. No CrossOver payload is used.
The installer does not change a Wine prefix or game files.

The release is MIT licensed and targets **macOS 15.0 or newer**, despite the
source build documentation's broader Sonoma requirement. It contains an x86_64
Unix library, so Apple Silicon requires Rosetta. Upstream source compilation
requires LLVM 15 and Xcode 16's Metal tools; the verified release avoids installing
that toolchain. Its release and source provenance are recorded in `manifest.json`.

After building standalone Wine:

```sh
./build-standalone-graphics.sh --wine-runtime "$PWD/runtime/standalone/wine"
./build-standalone-probes.sh
```

The first command installs the five DXMT binaries into our standalone Wine's
`lib/wine/` tree, backing up displaced Wine binaries under DXMT's `wine-originals/`.
This is necessary because installed Wine 11.8 searches its own DLL directory
before `WINEDLLPATH`. Re-run this command after reinstalling Wine. It also links
our Wine's `ntdll.so` and `winemac.so` into DXMT's separate staging directory.
DXMT's upstream `@rpath` entries resolve these relative to `winemetal.so`.
The Windows DLLs retain their Wine builtin markers. The launcher can retain the
DXMT directory itself in `WINEDLLPATH` and must use:

```text
d3d11,dxgi,d3d10core,winemetal=b
```

DXMT v0.80 supports Direct3D 10/11, not Direct3D 12. The standalone launcher
disables Direct3D 12 with `d3d12,d3d12core=`. Minecraft 1.26.5203.0 successfully
falls back to Direct3D 11, reports feature level 11.1, and reaches gameplay.
The user confirmed it working on September 29, 2026. This was tested in the
separate standalone prefix; the earlier CrossOver bottle remains intact.

DXMT v0.80 expects a legacy Wine macOS window-data layout. Standalone Wine uses
`patches/standalone-wine-dxmt-abi.patch` to export an adapter table with that layout,
keeping Wine's own internal layout unchanged. Merely creating a D3D11 device
does not exercise this window bridge.

`runtime/standalone/probes/standalone-graphics-probe.exe` creates a hidden window,
requests a hardware FL11.0 device and swapchain, clears a GPU texture red, reads
it back, and presents. Success requires `RedPixel=0xFF0000FF` and successful HRESULTs
(an occluded presentation status is acceptable). It has a 45-second watchdog and
does not show a game window. This probe checks the basic GPU/window bridge;
it does not cover every shader or gameplay scenario.

`standalone-graphics-shader-probe.exe` extends coverage without a game window:
it compiles vertex and pixel shaders, samples a 4×4 texture, and checks every
pixel after GPU readback. A second shader discards alternating pixels and checks
the resulting checkerboard. Both cases passed on September 30, 2026; see
`build/dxmt/shader-probe.log`. This covers basic shader translation and discard,
not Minecraft's full material library. Starting even a hidden-window Wine probe
can activate the Wine application, so run probes while gameplay testing is idle.

The original swapchain probe optionally accepts `BEDROCK_GRAPHICS_STRESS_FRAMES`
(capped at 1,200) for a bounded presentation soak. Setting
`BEDROCK_GRAPHICS_STRESS_AUTORELEASEPOOL=1` wraps each presentation in DXMT's
autorelease pool for allocation diagnosis only. These options do not modify the
runtime or enable a game workaround. Initial evidence showed slower host-memory
growth with a pool; this is not yet an established explanation of the overnight
Minecraft hang, nor a verified production fix.

The September 30 hang had about 20.7 GB in native `MALLOC_TINY`/`MALLOC_SMALL`
regions, versus about 390 MB in IOAccelerator allocations. That points toward
host allocations; it does not establish which caller caused the hang.
DXMT v0.80's per-frame `WMTQueryDisplaySettingForLayer` reads Cocoa display
properties without an autorelease pool. A narrow experimental adapter wraps
only that scalar-returning call, preserving the other 131 Unix-call entries.
It leaves calls returning borrowed objects alone.

Build the candidate separately, then explicitly stage its recorded bytes into
a stopped test runtime:

```sh
./build-standalone-dxmt-pool.sh
./build-standalone-dxmt-pool.sh --stage-existing-runtime /absolute/path/to/test-wine
```

This does not run from the normal graphics installer. The builder pins the
original v0.80 binary hash and Unix-call layout; the stage operation validates
both artifact hashes and the adapter source hash. The original library remains
beside the adapter as `winemetal-upstream.so`. Use
`BEDROCK_DXMT_DISPLAY_QUERY_POOL=0` for control and `=1` for the candidate.
Do not set the probe's separate `BEDROCK_GRAPHICS_STRESS_AUTORELEASEPOOL` during
this comparison. Reinstalling normal DXMT restores the original entry library.

The candidate with SHA-256
`daad45337c6e9a05256d31163fcb68e5502e6ab12ea69a9da45312dc9bb9b015`
passed clear/readback, textured shader, discard shader, and 1,200 presentations.
In equal-length presentation runs, observed steady RSS growth fell from roughly
64 KB/s to 28 KB/s. These short measurements include allocator noise and do not
prove an overnight game-memory fix. Logs are `build/dxmt/shim-control*`,
`build/dxmt/shim-pooled*`, and `build/dxmt/shim-standalone-graphics-*`.
This narrow adapter was used only for diagnosis; the gameplay runtime now uses
the corrected source rebuild described below.

The source audit also found unreleased ColorSync profiles/tags during DXGI
output construction and no pool around the finish thread's Metal diagnostics.
`patches/standalone-dxmt-memory-lifetime.patch` records source fixes for those
paths and the display query. The narrow adapter does not implement these
additional fixes. A full DXMT rebuild needs LLVM 15 and Xcode's Metal toolchain;
this machine currently has Command Line Tools and no `metal` executable.

A partial rebuild is possible without those tools: `build-standalone-dxmt-unix.sh`
compiles only `winemetal_unix.c` with the query/output pools and ColorSync releases.
It links to the unchanged upstream library for its exported shader compiler and
cache functions, preserving the upstream shader binaries. The C++ finish-thread
pool is excluded. Output remains under `build/dxmt-memory-unix/`; nothing is
installed into the normal runtime. The builder checks the source commit, original
binary hash, Unix-call layout, and the expected source changes after patching.
These source fixes are always enabled in the rebuilt bridge; the earlier
`BEDROCK_DXMT_DISPLAY_QUERY_POOL` switch applies only to the narrow adapter.

The opt-in qualification and staging flow is:

```sh
./build-standalone-dxmt-unix.sh
./build-standalone-dxmt-unix.sh --validate
# After gameplay qualification, stop the target runtime before staging:
./build-standalone-dxmt-unix.sh --stage-existing-runtime "$PWD/runtime/standalone/wine"
```

`--validate` makes a disposable APFS clone of standalone Wine and a private Wine
prefix, installs the candidate only there, runs both rendering probes, and records
their exact binary hashes. It can briefly activate Wine. Set
`STANDALONE_WINE_RUNTIME` to use a different base runtime. Alternatively,
`--validate-runtime /absolute/path/to/test-wine` tests an existing isolated runtime
whose graphics pair already matches the build.

Staging verifies the original source, four input headers, patch, trace source,
patched source, and both output hashes. It requires a matching render-validation
record; rebuilding different bytes invalidates that record. It refuses mapped
target libraries, preserves the original library under `dxmt-unix-bridge-backups/`,
and atomically replaces the dependency, entry library, and manifest in order.
Any failed commit or final hash check restores the previous files. The installed
manifest is `dxmt-unix-bridge.json` at the Wine runtime root. Transaction regression
tests run without Wine using
`python3 -m unittest discover -s tests -p test_standalone_dxmt_unix.py`.

To restore the official graphics implementation, rerun
`build-standalone-graphics.sh --wine-runtime <stopped runtime>`. It refuses mapped
graphics files and clears optional bridge manifests only after all five official
payloads pass hash verification. Displaced binaries remain backed up.

The optional `BEDROCK_DXMT_DISPLAY_TRACE=1` logs only elapsed time and counts of
layer queries and output descriptions. This distinguishes per-frame temporary
allocations from repeated output enumeration without logging account data.
`display-memory-probe` is a native, headless allocation diagnostic built alongside
the bridge. Run it separately against each library:

```sh
build/dxmt-memory-unix/display-memory-probe "$PWD/build/dxmt-memory-unix/winemetal-upstream.so"
build/dxmt-memory-unix/display-memory-probe "$PWD/build/dxmt-memory-unix/winemetal.so"
```

Across 2,000 calls, upstream retained about 4.6 MB versus roughly 25 KB with the
patched bridge, with identical reported display values. Each call already has an
autorelease pool in this diagnostic, isolating the owned ColorSync objects.
The original output-description leak is about 2.3 KB/call: explaining 20 GB over
nine hours would require roughly 280 calls/second. Main-menu growth observed in
Minecraft was much smaller, so the overnight hang's cause remains unproven.

An initial scripted bridge build accidentally skipped its patch due to a path
filter; it is useful only as a tracing control. The corrected builder explicitly
asserts the applied source changes. Candidate 3 records patched-source and binary
hashes in `unix-bridge-manifest.json`; the bridge hash is
`567e2afef0f00d3f93f68e17eb4b9dde24cb9e6a2d4b211f54e0e9c6fb0e8ff3`.
That exact candidate passed the hardware clear/readback/Present probe and both
texture and discard shader readbacks. Logs are
`build/dxmt-memory-unix/candidate3-standalone-graphics-*.log`.

In a five-minute Minecraft comparison, native tiny-allocation growth fell from
about 7.4 MB to 0.36 MB. The game made roughly 100 layer queries per second but
only two output-description queries at startup. Local-world loading, movement,
and saving passed with the corrected bridge. After fresh isolated validation,
the exact recorded pair was installed into the normal standalone runtime on
September 30. The normal launcher then passed a Lifeboat join, movement, and
disconnect with the new account helper and token-refresh runtime. The game held
about 2 GB of physical memory during that short online session. Fullscreen through
Video settings, fullscreen UI input, and return to the original window size passed.
These bounded tests do not prove the overnight freeze is resolved.

The subsequent September 30 gameplay session captured 654 samples over
1 hour 51 minutes using the corrected normal runtime. The user confirmed
multiplayer with an Xbox player. Physical footprint ranged from 4.18 to
5.15 GiB, macOS memory pressure stayed normal, the swapout counter did not
increase, and the launcher exited with code 0. No macOS crash was recorded.
This is stronger gameplay evidence, but still shorter than the earlier
nine-hour freeze; overnight stability remains unverified.

A growth alert and the user's report of slight lag prompted two diagnostic
captures around 3:45 p.m. Pacific. Both memory maps and thread samples completed.
Native malloc allocated about 81 MiB at capture; much of the footprint was in
Wine reserve, graphics, and owned unmapped memory. The thread samples contained
unresolved Rosetta frames and repeated Wine syscall-dispatch frames, limiting
attribution. The game log contained startup graphics warnings without a new
connection timeout or device-lost error. These observations establish neither
a memory leak nor the cause of the lag. No additional graphics fix was justified
by this evidence. See the [session results](README.md#september-30-gameplay-session);
raw diagnostics remain private under `logs/standalone/monitor/`.

The same probe builder produces the existing account and Store-callback probes.
It copies only the owner's `MicrosoftGame.Config` beside these probes, as required
by GDK, and leaves the original game directory unchanged. All generated output
stays under ignored `runtime/`.

On 2026-09-29, the standalone Wine 11.8 + upstream DXMT v0.80 package passed both
device creation and the hidden-window probe on this M4 Pro / macOS 15.3.1.
The swapchain, GPU readback, and presentation returned `S_OK`; the red pixel
matched `0xFF0000FF`. Evidence is in `build/dxmt/swapchain-probe-dxmt.log`.
An initial `E_FAIL` came from Wine's own D3D11 DLL shadowing DXMT, resolved by the
installation overlay above. The subsequent Minecraft test confirmed the D3D11
fallback and working gameplay. Inspection of the live game process found the
standalone Wine and DXMT Metal library loaded, with no CrossOver or D3DMetal
files mapped. A later test entered the Lifeboat online lobby with other players.
The local save was reopened, moved in, and saved successfully on September 30.
The September 30 session above subsequently confirmed Xbox multiplayer.
PS5 friend sessions, active Realm gameplay, and overnight stability remain
untested.

## October 5 performance investigation

No new performance optimization was installed. The acceptance criterion is less
CPU/RAM at the same graphics settings and workload; lowering render distance,
resolution, or frame rate does not meet it. Experiments use disposable prefix and
runtime copies under ignored `build/performance/`. Normal saves and settings are
unchanged.

At the existing 48-chunk view distance, a 30-second sample after several minutes
in the copied local world averaged 421.8% game CPU plus 13.0% wineserver CPU
(about 4.35 cores), with a combined 4.01 GiB physical footprint. Presentation
call cadence was about 51.6/s. This is not a displayed-frame or stutter metric.
Terrain generation was still active; elapsed time, camera, and world state must
be controlled before attributing differences to a patch.

- A Wine 11.8 port of the experimental WFUSync backend loaded the game. Its
  kernel32 synchronization test had the same pre-existing unexpected-success
  result as the baseline and no additional failures. The initial gameplay
  comparison did not establish a significant saving; it was insufficiently
  controlled to credit small differences. The backend remains experimental.
- A separately rebuilt DXMT v0.80 D3D11 DLL instrumented the device mutex and
  included an optional bounded-spin/blocking prototype. The original spinning
  mode recorded zero contention through more than 14,000 presentation calls,
  including several thousand in the local world. Changing that mutex therefore
  cannot improve the measured workload. The blocking mode was not promoted or
  qualified for deployment.
- A direct CPUID probe confirmed `ROSETTA_ADVERTISE_AVX=1` exposes AVX/AVX2 on this
  Mac, while OSXSAVE remains absent. A fresh Wine server reports the AVX feature
  bits, but inspected CPU-dispatch routines in the installed game also require
  OSXSAVE/XGETBV. The switch alone is not evidence of an AVX speedup; no game
  performance gain was established or configuration change deployed.

The rebuilt Windows graphics DLL reuses the exact embedded Metal library from
the pinned upstream release and the existing corrected Unix bridge. Build
scripts, compiler checksum verification, probe programs, samples, and measurement
JSON are retained in `build/performance/`. `measure.py` converts proc_pid_rusage
CPU counters using this host's Mach timebase; presentation counts come from the
existing optional display trace. macOS stack samples contain unresolved Rosetta
frames and cannot reliably divide all CPU time between game and adapter. Native
malloc allocation was approximately 69 MiB in one capture, while Wine and
graphics memory accounted for much more; that snapshot does not establish a leak.

Further optimization needs a repeatable, fully loaded scene and better symbolized
CPU/allocation profiles. These experiments do not meet the requested significant
performance improvement, and do not justify a broad synchronization rewrite.

## 2026-10-05: shared-buffer update optimization

A focused DXMT change produced a repeatable gain without changing graphics
settings. On Apple GPUs, eligible buffers now use shared memory and receive CPU
writes directly through their mapped address. The existing resource lifetime,
renaming, fences, and logical view flags remain in use. Intel/discrete GPUs retain
the original managed-memory path. Apple documents shared storage for this purpose:
https://developer.apple.com/documentation/metal/mtlstoragemode/shared

The tested scene issued 13,765 buffer updates per frame. Avoiding the Wine/Metal
bridge call for each update improved frame throughput in two alternating pairs:

| Pair | Bridge writes | Direct writes | Throughput gain | CPU work per frame |
| --- | ---: | ---: | ---: | ---: |
| 1 | 50.7 frames/s | 68.5 frames/s | 35.3% | 76.4 → 70.4 ms (7.9% less) |
| 2 | 53.3 frames/s | 79.3 frames/s | 48.7% | 77.7 → 70.1 ms (9.7% less) |

These are Present-return intervals from one fixed paused scene on this Mac, not
independently measured displayed FPS or a guarantee for every world. Both A/B
modes used shared allocations; the switch isolated bridged versus direct writes.
Each sample lasted 20 seconds after 7 seconds of settling. Draw/update counts,
view distance (48 chunks), resolution, textures and vsync stayed the same. Earlier
calibration runs hit Minecraft's pause-menu idle throttle and were excluded.
Total CPU utilization increased as more frames were produced; RAM stayed about
3.95–3.96 GiB. This establishes improved throughput and CPU efficiency, not lower
uncapped total CPU or a RAM saving.

The clean release build contains only
`patches/standalone-dxmt-shared-buffers.patch`; it has no profiling counters or
file-polling benchmark switch. The shader library and native Metal bridge are
reused unchanged. `docs/dxmt-shared-buffers-results.json` preserves the measurements.
`tests/dxmt-shared-buffers.cpp` tests 32,768 queued constant-buffer updates with GPU
readbacks across allocation reuse; the original and optimized builds both passed.

Build and deploy (close the target game first):

```sh
python3 standalone-dxmt-shared.py build
python3 standalone-dxmt-shared.py stage
```

The builder uses the locally installed LLVM MinGW and Meson tools under
`build/performance` by default; `--toolchain` and `--python` accept alternative
locations. It pins DXMT's source revision, initializes its pinned submodules, and
checks the upstream archive and embedded shader hashes. Artifacts and provenance
are saved under `build/dxmt-shared-buffers`. Staging backs up both the previous DLL
and its manifest, updates both runtime copies, and verifies their checksums.
The original graphics release can be restored with:

```sh
python3 standalone-dxmt-shared.py restore
```

The optimized DLL also supports `DXMT_CONFIG='d3d11.sharedManagedBuffers=False'`
to select the original allocation/write path for a diagnostic run. Reinstalling
the upstream graphics release replaces this local optimization.

### Packed constant buffers (2026-10-05)

`patches/standalone-dxmt-packed-constants.patch` extends the shared-memory build.
On Apple unified-memory GPUs, DEFAULT constant buffers use DXMT's existing
4 KiB page suballocation and write-combined CPU cache policy. Full updates already
follow the dynamic rename path; packing preserves its allocation lifetime and GPU
synchronization while reducing the number of separate Metal buffer objects.
Buffers larger than a page continue to use separate allocations. Other buffer
bindings and non-Apple GPUs retain their previous behavior.

Two alternating A/B pairs in the same process and paused, fully loaded scene gave:

| Measure | Shared-memory baseline | Packing + write-combined |
| --- | --- | --- |
| Present-return throughput, pair 1 | 78.97/s | 79.40/s |
| CPU work per frame, pair 1 | 76.48 ms | 62.93 ms (-17.7%) |
| Present-return throughput, pair 2 | 80.22/s | 79.86/s |
| CPU work per frame, pair 2 | 76.64 ms | 62.96 ms (-17.8%) |

These are incremental improvements over the previous shared-buffer optimization.
Graphics settings stayed unchanged. This demonstrates less CPU work at essentially
the same throughput, not a further substantial FPS increase. RAM did not fall
consistently. Measured GPU command-buffer time fell about 48–50%; overlapping
command durations do not measure GPU utilization or power. Results apply to this
scene on an M4 Pro, not every world. Exact measurements and limitations are in
`docs/dxmt-packed-constants-results.json`.

Packing with default CPU cache reduced CPU work but lowered throughput 3–7%, so the
selected build combines packing with write-combined cache. An additional shortcut
for UpdateSubresource showed no material throughput gain and was excluded.
The production patch includes no profiling counters, file polling, experimental
pool switching, or update shortcut.

Build and stage this separate profile with the game closed:

```sh
python3 standalone-dxmt-shared.py build --packed-constants
python3 standalone-dxmt-shared.py stage --packed-constants
```

Artifacts are in `build/dxmt-packed-constants`. The profile keeps an independent
backup of the previously installed DLL and DXMT manifest, preserving the original
shared-buffer profile and its upstream backup. Roll back this second optimization:

```sh
python3 standalone-dxmt-shared.py restore --packed-constants
```

The runtime options `d3d11.packDefaultConstantBuffers=False` and
`d3d11.constantBufferWriteCombined=False` independently disable packing (and its
cache policy) or just write-combined cache for diagnostics. Defaults are enabled
only in the explicitly selected packed profile.

`tests/dxmt-constant-buffers.cpp` validates 32,768 updates per case through GPU
readback, allocation reuse, initial data, buffer copies, deferred command replay,
and immediate updates between replays, with multithread protection enabled.
The release matrix covers 16, 256, 4096 and 4112 byte buffers, immediate/deferred
contexts, packing on/off and shared/managed storage. Validation outcomes and
installed build provenance are recorded in the results JSON.

### Wine small-allocation reuse (2026-10-05)

`patches/experimental-wine-heap-reuse.patch` increases the process heap's
48-byte LFH free-group retention threshold from 33 to 4096 groups (roughly
6 MiB). It reuses existing Wine group ownership and atomic operations; private
heaps and other allocation classes keep their original behavior. Concurrent
releases can briefly exceed the threshold. This follows
[Roritharr's allocator research](https://github.com/Roritharr/bedrock-on-macos/blob/main/docs/performance.md),
independently tested here with WineGDK 11.8, DXMT 0.80 and M4 Pro.

With the existing packed-buffer graphics build and unchanged 48-chunk settings,
fully loaded control runs measured **67.67–77.56 displayed FPS**, versus
**97.86–99.95 FPS** for the candidate. The 99.95 run was bracketed by the
77.56 and 67.67 control runs. These are Metal drawable presentation timestamps,
not just successful returns from Present. The scene approaches a 100 FPS
presentation ceiling.

A separate confirmation against the originally installed Wine DLL used the same
diagnostic graphics build on both sides:

| Measure | Original Wine | Heap reuse |
| --- | --- | --- |
| Displayed FPS | 63.19 | 98.62 |
| CPU work per displayed frame | 64.36 ms | 62.81 ms |
| Total CPU (100% = one core) | 406.5% | 619.5% |
| Process footprint, game + wineserver | 4.030 GiB | 4.054 GiB |

This is a substantial throughput gain in this scene. Total CPU rises with the
extra frames; CPU work per frame falls only modestly, and RAM does not decrease.
It is not a guaranteed gain across every world. Early measurements with
incomplete terrain loading were excluded. Clouds, entities and warmup timing
still vary between launches. Rosetta stack sampling did not establish the exact
critical-path mechanism. Full measurements, exclusions and checksums are in
`docs/wine-heap-reuse-results.json`.

The candidate and matching source control passed 2,398,208 allocation/free pairs,
8,192 reallocations, dirty/zero reuse, boundary sizes, private heaps and
cross-thread frees. Eight staging/rollback fixture tests passed. A separate
isolated rebuild passed with identical recorded source inputs; embedded build
paths change binary data addresses, so it is not byte-identical.

Build and explicitly stage this optional profile with the target game closed:

```sh
python3 standalone-wine-heap.py build
python3 standalone-wine-heap.py stage --wine runtime/standalone/wine
```

The artifact and provenance live in `build/wine-heap-reuse`. Staging changes only
the Windows `ntdll.dll` and its runtime metadata, with checked backups of both.
The standard Wine builder does not automatically apply this experimental patch.
Restore the exact previous DLL and runtime manifest with:

```sh
python3 standalone-wine-heap.py restore --wine runtime/standalone/wine
```

### Reuse identical input layouts (2026-10-05)

This profile is **installed in the normal launcher**, alongside Wine heap reuse.
The clean release check measured 99.69 FPS and 55.71 CPU ms per displayed frame.
That separate-process check is a sanity test; the paired comparisons below
estimate the improvement.

`patches/standalone-dxmt-input-layout-reuse.patch` avoids invalidating a prepared
render pipeline when the same canonical, immutable input layout is rebound.
This applies only when vertex and pixel shaders are bound and geometry,
hull and domain shaders are absent. Depth-only and emulated geometry/tessellation
paths retain existing behavior. The comparison stays under the context lock.

A diagnostic build found about 7,000 layout bindings per frame in the fixed
benchmark scene; 99.59% were identical. Repeated off/on comparisons in one process
showed these incremental results on top of heap reuse and packed constants:

| Measure | Reuse off | Reuse on |
| --- | --- | --- |
| Displayed FPS, pair 1 | 94.04 | 99.69 |
| CPU work per displayed frame, pair 1 | 63.66 ms | 61.84 ms |
| Displayed FPS, pair 2 | 96.40 | 99.92 |
| CPU work per displayed frame, pair 2 | 60.92 ms | 56.95 ms |

The encoder thread's CPU work approximately halved. Overall CPU work per frame
fell 2.9–6.5% in those pairs. A later on capture measured 97.86 FPS and 58.49 ms.
This is a modest additional gain near the scene's 100 FPS presentation ceiling;
it is not a second gain of the size produced by heap reuse.

The initial short comparisons suggested a memory regression, so installation
was held. Follow-up high/low VM snapshots found the same approximately 414 MiB
owned-unmapped memory pulse with both this shortcut and the previous packed
build. The shortcut therefore did not introduce this behavior. The underlying
owner and long-term behavior remain unresolved; no RAM reduction is claimed.
These diagnostic snapshots are not performance comparisons. Exact evidence and
deployment status are in `docs/dxmt-input-layout-results.json`.

`tests/dxmt-input-layout.cpp` passed 31 GPU readback cases and seven state checks
with the diagnostic shortcut disabled and enabled, then with the clean release
build. Cases cover repeated/changed/null layouts, shader changes, render-target
format, blend/sample-mask/topology changes, depth-only rendering, ClearState,
and deferred command replay with context restoration enabled and disabled.
The release DLL contains no frontend profiling, timers or control-file polling.

Build and stage the separate profile with the target game closed:

```sh
python3 standalone-dxmt-shared.py build --reuse-input-layout
python3 standalone-dxmt-shared.py stage --reuse-input-layout
```

This includes the existing shared-buffer and packed-constant patches. Its
independent backup preserves the previous packed graphics DLL and exact DXMT
manifest. Restore that previous graphics build with:

```sh
python3 standalone-dxmt-shared.py restore --reuse-input-layout
```

Heap reuse is independent and remains installed when this graphics profile is
restored. Source attribution and license notices are in `THIRD_PARTY.md`.


## Exact-build allocator ownership transfer (private experiment)

`patches/experimental-bedrock-refmove.patch` removes three redundant temporary
reference copies in Bedrock's ring allocator. Each output receives an already
owned reference, so the matching increment and immediate decrement disappear.
Reservation, admission, byte accounting, the real ownership increment, and
completion-based retirement remain intact. This is a code optimization; graphics
settings and world content are unchanged.

The hook runs before executable TLS callbacks and entry. It requires an explicit
gate, exact full-file SHA-256, PE identity, and matching loaded function bytes.
Only six sites in process memory change; the owned game file on disk is unchanged.
An unsupported game build is refused. This is specific to Windows Bedrock
1.26.5203.0, pinned WineGDK 11.8, and the separately validated 48-byte heap profile.

The verified allocator and input-layout profiles are installed in the normal
standalone runtime. In the matched camera scene, the combined capture used
49.53 CPU ms/displayed frame versus 58.12 for the initial control (14.8% less),
at 99.59 versus 99.95 displayed FPS. Allocator-only used 52.94; a reversal
control used 59.94. The reversal followed user movement and a position reset,
so it is corroboration rather than an identical-world sample. No RAM saving
is established. Measurements and deployment status are recorded in
`docs/bedrock-refmove-results.json`. These are actual Metal display timestamps,
with game plus wineserver CPU per displayed frame. The earlier exploratory 14%
estimate is superseded because its saved camera pitch differed. Controlled runs
reset a private world fixture and command the same orientation; saved coordinates
and rotation are checked after shutdown. Results apply to one paused outdoor
scene on M4 Pro, not every world, movement, frame latency, or energy consumption.

The real x64 instruction harness passed 60,426 descriptor checks under
Wine/Rosetta, including seven concurrent producers, releases during production,
and 19,110 references held after the outer owner is destroyed. Backing and control
memory are freed exactly once. A separate ownership model passed 1,344,000 calls
per variant. A TLS sentinel verified execution before entry, page protection
restoration, off/on/off reversal, and rejection of altered executable hashes.
General slow paths and exception cleanup are outside dynamic harness coverage;
the edited fast-path spans were checked against the actual unwind metadata.
These tests do not establish whole-program correctness for a closed executable.

The staging helper defaults off. The launcher removes inherited experiment flags
and enables only a complete, checksum-verified profile with an explicit request.
For the frozen locally validated artifact, while the game is closed:

```sh
python3 standalone-bedrock-refmove.py stage --wine runtime/standalone/wine --enable
```

Restore this overlay before restoring the older heap profile:

```sh
python3 standalone-bedrock-refmove.py restore --wine runtime/standalone/wine
```

Staging journals the previous DLL and runtime manifest and refuses active or
mismatched runtimes. The source export includes the helper, patch, and fixture
tests, not compiled Wine or game binaries. `build` writes separate review
artifacts; it does not promote a new compiler output into the frozen tested
artifact. A new binary requires its own validation before use.

## October 6: display-paced presentation queue

The normal standalone launcher now enables the locally built presentation-feedback renderer through a hash-checked `runtime/standalone/wine/frame-pacing.json` stage. The native bridge enables Metal display sync and bounds pending presentations to two per layer (50 ms bounded wait when the display stops delivering callbacks). D3D command-queue latency is capped at one; the additional duration limiter stays disabled. Graphics quality, resolution and 48-chunk render distance remain unchanged; the earlier VSync-off game option remains in place.

The clean build reuses the release objects containing shared buffers, packed constants and input-layout reuse. The native bridge retains the existing ColorSync and autorelease fixes. Presentation tracing is optional and off in normal launches. No experimental CPU timer or two-drawable override is included.

Validation: both graphics/readback probes passed on the exact staged binaries. A 30-second title capture measured 99.62 presentations/s, p99 9.9915 ms, one 49.96 ms interval and no intervals above 50 ms. Median submission-to-presentation time fell from 28.88 ms in the earlier 100 FPS baseline to 19.34 ms. A 30-second loaded-world capture measured 95.59 presentations/s, p99 19.9827 ms and maximum 19.9828 ms, with no intervals above 33 ms. All callbacks in those windows were positive, with a single 1683x951 layer and no capture issues. These are presentation measurements, not physical input-to-photon measurements or a guarantee against all future hitches.

Loading still includes separate CPU-side pauses before Present (537 ms in a traced reload). This change does not claim to remove those stalls. The original user world was not used for diagnostic edits.

Rebuild: `python3 build-standalone-frame-pacing.py`. Evidence: `build/dxmt-frame-pacing/render-validation.json` and `build/performance/stutter-20261006/{menu-release-feedback2,world-release-feedback2}.json`. Staging backup: `runtime/standalone/wine/frame-pacing-backups/20261006-105350`; `restore.json` maps every replaced runtime/prefix file to its backup. To disable this stage at the next launch, set `enabled` to false in `frame-pacing.json`; retain the binaries or restore all recorded files while the game is closed.

## October 6: metrics overlay

The HUD candidate adds a 276×154 point native layer, inset 18 points from the game viewport’s top right. It follows resizing/fullscreen and has no input surface; F8 toggles its visibility. It shows actual distinct Metal presentation timestamps as a two-second rolling FPS/mean frame interval, a recent frame-time graph, this game process’s CPU share of all active cores, and physical memory footprint in GiB. Empty/occluded presentation windows show a dash instead of fabricated FPS. The overlay redraws twice per second, keeps a bounded 512-sample ring, and writes no per-frame logs. Native frame pacing is preserved.

Source: `standalone-metrics-hud.m` and `.h`; builder: `build-standalone-metrics-hud.py`; local output and stage script: `build/metrics-hud/`. The exact bridge passed GPU, texture, and discard readback probes; its top-right placement was visually checked in a window and fullscreen, and F8 hiding was checked. A presentation-overhead capture was interrupted by screen changes and rejected; no numerical overhead improvement or zero-cost claim is made.

The normal launcher only sets `BEDROCK_METRICS_HUD=1` when its verified frame-pacing manifest contains `metrics_hud: true`. The native bridge must be installed while the normal game is closed. Stage: `python3 build/metrics-hud/stage.py`; it saves the prior bridge and both runtime manifests under `runtime/standalone/wine/hud-backups/`. The stage was prepared pending the user’s saved-session response.

The HUD installer uses `runtime/standalone/wine/pending-hud.json` when a candidate is queued. The normal launcher checks the pinned bridge, validation record and staging script after acquiring its lock and before preparing the next game launch. No live library is replaced. User confirmation is still required before closing a currently running unsaved session.

### HUD rollback after startup crash (2026-10-06)

The normal launch at 12:11:30 crashed in Wine `heap_free_block + 0x126`
(RVA `0x27016`) while writing through an invalid free-list pointer. This locates
the detected corruption, not its source. The process had closed before recovery.
The pre-HUD bridge and both manifests were restored from
`runtime/standalone/wine/hud-backups/20261006-121129`; existing presentation pacing
remains enabled. The 12:16:28 normal relaunch remained running without a recorded
fault for more than six minutes. No pending HUD marker remains, and staging this
candidate is blocked in its validation record.

With presentation tracing disabled to match production, an isolated HUD session
loaded the copied creative world, saved it, and returned to the world list.
A second startup using copies of the normal roaming profile and resource cache
also reached the title screen with the HUD. Neither reproduced the crash; this
does not establish safety or prove the HUD caused it. Both test processes were
closed; the previous diagnostic profile was restored and the reproduction copy
preserved. Original worlds were not edited by these tests.

Evidence is in `build/metrics-hud/crash-20261006-121155/findings.json` and its saved
launch log. Normal WineDbg `ShowCrashDialog` is now 0 so any subsequent crash
prints an automatic backtrace to the launch log; the previous registry value is
saved with that evidence. The metrics overlay remains disabled pending diagnosis.

## October 6: render-allocation candidates

The next experiments target repeated ownership and allocation work while keeping
graphics settings unchanged. They use a copied runtime, prefix and world. The
normal runtime is not changed by the build commands below.

`python3 standalone-dxmt-shared.py build --borrow-constant-buffers` builds a
separate DXMT candidate in `build/dxmt-borrowed-constants/`. It borrows the bound
constant-buffer reference while encoding; GPU allocation retention remains in
the existing access path. The profile includes shared and packed constants,
input-layout reuse and the existing frame-latency support. It leaves the native
bridge unchanged. Staging this profile through the old stage command is refused.

The isolated candidate passed the existing graphics matrix and a new ownership
lifetime probe: baseline and candidate each checked 65,536 GPU values and 16
binding-restoration cases, including null bindings, DISCARD, early application
release and deferred replay. `tests/dxmt-constant-buffer-lifetime.cpp` retains
that probe. This establishes those tested lifetime behaviors, not a gameplay
speedup. A first game comparison was excluded because its saved camera differed.

The conservative exact-current candidate has a separate builder:
`python3 standalone-bedrock-allocator.py build --source <pinned-standalone-wine-source>
--wine <dependency-runtime> --output <isolated-output>`. It specializes the
verified current-arena call for requests through 1024 bytes while preserving
the game's admission, fallback, ownership and exception behavior. Its modes are
`BEDROCK_EXACT_CURRENT=off|control|fast`; enabled modes require the existing
refmove gate and reject simultaneous allocation diagnostics. It is disabled by
default and the builder has no staging operation. A new build is a new artifact
that requires validation, even when the source is identical.

`python3 tests/run-bedrock-exact-differential.py --game <owned-Minecraft.Windows.exe>
--output <ignored-output>` compares the implementation with locally extracted
instructions from the exact supported executable. Both original and refmove
variants passed 16,000 randomized cases, 57,344 concurrent calls and 20 fallback
boundary checks each. The rebuilt DLL also passed isolated off/control/fast/
control sentinel runs, exception unwinding, unrelated-caller exclusion and
negative hash/flag checks. No proprietary function bodies are distributed in
these test sources.

The allocation diagnostic recorded 104,804,434 calls and matching normal returns.
98.46% requested more than 512 bytes; the recent bounded samples were dominated
by 528-byte requests. A 512-byte optimization cutoff would therefore miss most
calls. Token-keyed identity counters overflowed, so that capture cannot establish
frame lifetimes or retained-memory requirements.

The target machine is an M4 Pro with eight performance cores, four efficiency
cores, 24 GiB memory, 16 KiB host pages and 128-byte cache lines. An isolated
seven-worker synthetic test favored 16 KiB chunks over 4 KiB chunks for the
sampled request mix (median 19.01 versus 43.65 ns per allocation, wall time divided
by total calls, five trials). The 64 KiB result was 18.25 ns with slightly higher
retention. These noisy Rosetta results only select a starting configuration for
live testing; they do not measure game FPS or establish a native ARM build.

A later direct comparison ran locally extracted post-refmove original allocator
instructions against the actual slab C core, both x86-64 under Rosetta. Eleven
alternating pairs used identical copies and delayed reads, with one or seven
producers. For the bounded observed size mix, median allocation-plus-copy wall
time per total allocation fell from 36.89 to 24.91 ns with one worker, and from
233.25 to 9.97 ns with seven contending workers. All 88 timed runs validated;
the slab won all eleven pairs for that mix. The all-528 case improved by 18.7%
and 94.8% respectively, with noisier single-worker results.

These are saturated microbenchmark results, not Minecraft frame-time gains.
Seven producers continuously contended on one original arena; the game's actual
contention and eligible call coverage remain unmeasured.
Original backing was preallocated and resident; original growth and seal/reclaim
were excluded, and unexpected slow-path entry aborted the test. Slab refills,
copies and real temporary backing-reference releases were included. Neither the
Wine heap backend nor game hook dispatch was measured. Slab cleanup cost more,
and retained storage was about 1.3% higher for the seven-worker observed mix.
The test game was temporarily suspended during timing and resumed afterward.

The larger candidate is built by `standalone-bedrock-frame-slab.py build` using
the same explicit source, dependency-runtime and isolated-output arguments. A
small C core owns per-frame chunks; the version-specific adapter registers
verified frame tokens and holds one lease per worker task. Cached allocations
avoid shared atomic operations. Storage is released only after the complete
native frame reset/destructor returns. Exceptions retain uncertain storage
within explicit caps and subsequent requests fall back to the original path.
The three pools together are bounded to 384 MiB; this is a maximum, not a claim
about normal retained memory. Worker state and telemetry use separate 128-byte
cache lines. The generic scope callback alone is not a retirement boundary.

In an isolated test runtime, the hook requires `BEDROCK_FRAME_SLAB=1`,
`BEDROCK_PRIVATE_REFMOVE_15203=1`, a fresh DOS path in
`BEDROCK_FRAME_SLAB_CONTROL`, and an initial `BEDROCK_FRAME_SLAB_CHUNK` of
0, 4096, 16384 or 65536. Other allocator experiments must be off. Missing opt-in
leaves the hook disabled; conflicting flags or a different executable are
refused before game entry. No staging command is provided.

Build the native controller before capturing measurements:

```sh
python3 standalone-bedrock-frame-control.py build
python3 standalone-bedrock-frame-control.py set --control <capture> --chunk-kib 16
python3 standalone-bedrock-frame-control.py status --control <capture>
# Only after the test game has exited:
python3 standalone-bedrock-frame-control.py decode --control <capture>
```

The setter performs one aligned atomic store. New settings apply to future
frames; existing frames retain their original pool through retirement. Status
reports individual atomic gauges, not a coherent snapshot or live per-thread
statistics. The decoder refuses an open mapping. OFF/4/16/64 KiB comparisons
must still control camera, focus, streaming warm-up and background compilation.
Machine tuning and synthetic tests do not substitute for live measurements.

The frozen tested DLL also has a separate local installation helper. After
quitting games that use this runtime, install it with:

```sh
python3 standalone-bedrock-frame-profile.py stage \
  --wine /absolute/path/to/runtime/standalone/wine \
  --artifact /absolute/path/to/validated/build-directory \
  --game-dir /absolute/path/to/game
```

The helper accepts only the qualified `24f230a1…` DLL and its pinned source
manifest. It journals the replacement, retains exact rollback files, and
preserves the existing heap/refmove records. It shares the regular launch lock
and refuses an active runtime. The regular launcher verifies this installation
before enabling 16 KiB slabs and creates a fresh private control file for each
game under `logs/standalone/frame-slab/`. Shell diagnostic flags cannot enable
it. Fresh or changed builds still require independent qualification.

To restore the previous runtime after quitting the game:

```sh
python3 standalone-bedrock-frame-profile.py restore \
  --wine /absolute/path/to/runtime/standalone/wine
```

This integration is for the source-development launcher. Packaging and signed
app distribution are separate validation targets. Historical experiments below
retain their original scope and measurements.

On October 7 this profile was **installed and enabled in the regular local
runtime**. Stage/restore/restage restored the prior DLL, manifest and retained
records byte-for-byte in both the lab and regular runtimes. All 190 Python tests
passed, including 32 profile transaction tests. Two copied-world sessions used
the regular launch gate, distinct private control maps, terrain transitions and
save/reload; both exited normally without observed visual corruption.

The first session registered 40,273 scopes and retired 40,269; its final map
retained four menu scopes and 65,664 bytes at process exit, with zero exceptions
or quarantines. This is not an all-scopes-drained result. In the second session,
an explicit OFF transition while the world was running retired all 8,535 scopes
and reached zero reserved bytes before normal exit. The regular
`Launch Standalone.command` subsequently loaded `24f230a1…` and logged the
16-site startup guard with 16 KiB slabs enabled. The game executable, authorized
account helper, DXMT DLL and Unix runtime modules retained their original
hashes. These are functional rollout checks, not additional FPS measurements.

The durable slab DLL (`24f230a1…`) passed the exact-game startup guard and a
live menu smoke test. OFF/16/4/64/OFF switching registered and retired 9,581
frames, handled 9,581 allocations, reported no quarantined frames or exceptions,
and drained to zero retained bytes and live scopes. The sum of individual pool
peaks was 430,560 bytes; it is not a simultaneous process-memory measurement.
The native UI connection then became unavailable, preventing world entry and
the controlled in-world comparison. The owned menu test process was stopped
only after checking that no copied-world database was open. The original game
and normal runtime modules still match their initial hashes.

A later retry opened the copied world's database, but its first OFF capture had
297 callbacks with zero presentation timestamps and no displayed frames. The
comparison was rejected before enabling the slab. The harness now requires an
open copied world and a recent stream of displayed frames before starting its
OFF/ON/OFF/ON/OFF sequence. Native desktop control remained unavailable after
recovery attempts. User-authorized AppleScript foregrounding later restored
displayed timestamps, but the next capture stayed near 10 FPS and exceeded the
presentation boundary-gap limit. That capture was also excluded. macOS denied
System Events access. The slab stayed OFF throughout both rejected captures.
These were historical failures; native control recovered after the October 7
Codex restart, and later tests entered the world without manual assistance.

A subsequent diagnostic measured CPU work in the loaded copied world without
claiming visible FPS. Five OFF/16/OFF/16/OFF windows each contained 297 or 298
unique, contiguous submitted frames, with adjacent boundary sequence IDs and
the same Metal layer and dimensions. All presentation timestamps were zero;
submission cadence stayed near 9.87 per second. The pause/visibility state and
camera could not be independently verified. OFF retained experimental hook and
counter overhead, so this is not a normal-runtime comparison.

Aggregate CPU cost per submitted frame was 61.53, 45.16, 58.24, 40.00 and 58.17 ms.
Interpolating between each ON window's neighboring OFF windows gives reductions
of 24.6% and 31.3%. Streaming-worker CPU accounted for most of the difference.
An independent audit recomputed the denominators and found no arithmetic error.
All 957 registered scopes retired after returning OFF, with zero retained slab
bytes and live scopes. The recorded sum of pool peaks was 18,845,568 bytes.
Those lifecycle counters include warm-up and callback-draining time, not just
the 30-second CPU windows. This establishes a repeatable CPU saving in this
specific occluded workload; it does not establish unchanged gameplay work,
foreground performance, visual correctness, or an FPS gain.

A subsequent October 7 foreground comparison completed OFF/16/OFF/16/OFF
with the binding observer disarmed. Aggregate CPU ms/displayed frame were
69.43, 54.82, 69.89, 54.58 and 62.97; displayed FPS were 73.67, 73.01, 72.50,
74.13 and 73.65. Interpolated neighboring controls give **21.3% and 17.8% less
CPU work**, with FPS changes of -0.1% and +1.4%. This establishes a repeated
CPU reduction within the experimental profile, not a demonstrated FPS gain.

The copied-world database was open, foreground focus was sampled every second,
and every timing window had positive presentation timestamps at 1,683 × 951.
The camera was visually unchanged before/after and no corruption was observed.
Daylight was not frozen in this sequence, and the last control's CPU declined.
OFF retains frame instrumentation and disarmed binding wrappers, so this cannot
by itself establish the benefit versus normal modules. Normal exit retired all
5,890 registered scopes with zero retained slab bytes, zero quarantines and no
thread-admission overflow. Lifecycle totals cover the entire session.

The pure slab DLL was then compared with exact copies of the normal runtime
modules, without either recurrence overlay. Daylight was frozen at noon and
camera orientation reset after each launch. Normal A used 61.89 CPU ms/displayed
frame at 73.22 FPS. Two candidate windows used 53.98 and 52.52 ms at 71.68 and
71.84 FPS. Normal C and two later windows used 72.29, 71.58 and 70.92 ms at
72.27, 72.13 and 71.77 FPS. All windows had valid foreground/presentation evidence.

This is **12.8–27.4% less observed CPU work across comparisons**, or 12.8–15.2%
against the lowest-CPU normal capture. Normal launches differed substantially,
so the range is an observation, not a precise causal gain. Streaming-worker
CPU fell from 29.6–33.6 to 18.4–18.7 ms/frame, supporting the intended mechanism.
FPS did not improve; p99 stayed about 19.98 ms under the shared 10 ms pacing.
The exact gain still needs tighter replication across independent launches.

An earlier candidate window was excluded because reload shifted the camera.
Later baseline windows remained heavier despite additional warm-up. Thermal
state was not recorded, world simulation continued, wineserver cost varied,
and process footprints changed; no power or memory improvement is claimed.
The candidate saved and exited normally, retiring all 21,202 tracked scopes
with zero retained slab bytes, exceptions or quarantines. Its normal-module
neighbors also exited normally. The normal game and all four runtime module
hashes were reverified unchanged. An independent numeric audit found no frame
denominator error and agreed that CPU savings are supported, while an FPS gain
is not established.

The conservative exact-current rewrite's first game capture did not reduce
aggregate CPU per displayed frame; its controls were excluded for visibility
and camera changes. All new candidates remain disabled in normal launches. Reproducible source checks passed 154 tests;
the export allowlist and checksum inventory were checked. Sanitized evidence is
in [render-redesign-results.json](docs/render-redesign-results.json).

## M4 architecture experiments, October 6

The next investigation targeted the actual M4 Pro: eight performance cores,
four efficiency cores, 24 GiB memory and 128-byte cache lines. A standalone
Rosetta client now sends retained AABB visibility batches to an ARM64 companion
through shared memory and semaphores. Both binaries use identical strict-float
source; 64 fixtures of 65,536 boxes match exactly, including malformed and
boundary inputs. This code has no game hook or runtime integration.

The final 11-pair run measured 43.13 versus 21.45 microseconds for 4,096 boxes,
and 180.77 versus 65.95 microseconds for 16,384, including communication. Batches
of 64 and 256 lost; the 1,024-box result changed sign between runs. These are
elapsed batch times, not aggregate CPU or FPS. Geometry extraction, updates,
draw submission and GPU execution are excluded. Visibility alone saves too
little absolute time to explain a large improvement in the measured game.
Commands and limitations are in [the testing guide](docs/TESTING.md).
An additional AVX2-targeted Rosetta versus Apple-M4-targeted ARM comparison
preserved the large-batch advantage. AVX2 did not improve this x86 kernel;
compiler target flags alone were not a demonstrated optimization. The stronger
original x86 baseline remains the appropriate comparison for the numbers above.

Two other isolated implementations were rejected for runtime integration:

- Padding 1,088-byte binding strides to 1,152 removed adjacent-worker cache-line
  overlap but produced approximately zero median combined improvement. Its
  larger working set and 16 game patch sites are not justified by these tests.
- Interning repeated binding records reduced synthetic producer-plus-consumer
  time by 14.6–23.9%, but unique records regressed 14.3–18.4%. Recycling/fusing
  clone construction also failed to establish a substantial parallel gain.

The larger remaining hypothesis is to retain unchanged chunk draw packets
before their per-frame reconstruction, then replay them through Metal indirect
command buffers. Game payloads demonstrably mutate before cloning, and a stable
chunk identity plus complete invalidation/lifetime contract is still missing.
Exact-byte recurrence instrumentation can measure potential reuse; recurrence
alone cannot authorize caching. No retained-packet FPS improvement or production
change is claimed. Sanitized results are in
[m4-architecture-results.json](docs/m4-architecture-results.json).

The next measurement tool is built: an opt-in clone-recurrence overlay on the
frame-slab candidate. It calls each original constructor once, observes only
after success and preserves its return/exception behavior. Three selected
callsites have separate 32-entry caches per registered thread, with 2,048-byte
payload limits, approximately 1/64 sampling and a 65,536-call per-thread cap.
Only numeric counters are exported. A fresh separate control mapping starts
disarmed; the normal runtime and launch settings are unchanged.

The overlay and native controller source are retained in
`patches/experimental-bedrock-clone-recurrence.patch` and
`clone-recurrence-control.c`. The overlay applies **after** the generated exact
frame-slab adapter/manifest in its isolated source tree; it is not a patch for
unmodified upstream Wine and no install command is provided. Build the control
tool with that source directory as its include path, then use
`recurrence-control <control-file> status|arm|stop`. The optional game flags are
`BEDROCK_CLONE_RECURRENCE=1` and a different fresh DOS path in
`BEDROCK_CLONE_RECURRENCE_CONTROL`, alongside the existing frame-slab gates.
CHUNK=0 avoids allocating slabs but leaves frame clocks unknown.

The candidate passed sanitizer, calling-convention, actual private Windows SEH,
shared-mapping and negative executable tests, plus the existing frame-slab
sentinel. Review found and fixed attribution of unrelated frame leases: clocks
now require clone-token equality.

On October 7 the observer ran in the isolated copied world after a normal game
quit and guarded runtime replacement. A bounded 20-second capture recorded
592,545 calls inside verified workers, zero ABI mismatches and zero exceptions.
At the dominant site, 8,862 of 8,902 sampled 528-byte payloads and their metadata
matched an earlier entry; 1,823 matches crossed known frame/scope clocks. The
seed site recorded 155 matches among 189 samples; the third site did not run.
These are sampled cache-window observations, not an unbiased reuse percentage
for every call. The observer then stopped and slabs returned to OFF with all
203 registered scopes retired and zero reserved bytes.

The capture ran while the game was occluded, so it establishes recurrence only.
Foreground FPS attempts failed preflight as focus moved to other applications.
A later attempt held foreground focus but still displayed about 10 frames/s;
no comparison phases ran in that session. Native control subsequently recovered
after the Codex restart, enabling the foreground slab comparison above. No
permission restriction was bypassed. Post-exit decoding of the older clone
session found 512 admitted thread slots and 511 overflow admissions; its bounded
clone observations must not be described as complete process coverage.

Snapshots are coherent per thread, not across the process. Stopping can leave
up to 255 outside-worker observations unpublished per thread. Sampling, the
small cache and independent worker histories can miss reusable state; do not
scale hit rates by 64 or infer that low counts disprove reuse. Observation adds
overhead and is unsuitable for performance comparison. This is an eligibility
probe, not a retained-packet implementation or a proven game optimization.


A separate binding-recurrence profile now measures the three 1,044-byte copy
sites directly. Its source is in
`patches/experimental-bedrock-binding-recurrence.patch`, with native controller
`binding-recurrence-control.c`. Apply this overlay after the exact frame-slab
adapter/manifest; do not combine it with the clone overlay. It preserves each
original copy and its return/exception behavior, then observes destination bytes.
The original 1,088-byte stride and unused tail remain unchanged.

Each admitted thread has one shared 32-entry history across all three sites and
a total 16,384-call budget. The original cached hash filters candidates; full
1,044-byte equality is required. Counters distinguish historical and consecutive
matches, including opaque source-address equality. They expose no addresses or
payloads. Source equality does not prove encoder identity or resource ownership.
The numeric mapping starts disarmed; stop/arm does not replenish the budget.

Build the native controller against the overlay's headers and use
`binding-control <control-file> status|arm|stop`. An isolated launch requires
`BEDROCK_BINDING_RECURRENCE=1`, a fresh separate DOS path in
`BEDROCK_BINDING_RECURRENCE_CONTROL`, clone recurrence off, and the existing
frame-slab gates. These settings passed the October 7 real-game launch below.
The mapping omits thread-admission counters: captured totals cover admitted
threads only. Decode the separate frame-control registered/overflow thread counts
after normal exit alongside captures; the earlier long-running slab session
exhausted its slots.

Native sanitizer, Rosetta calling-convention and actual Windows SEH fixtures
passed, including every single-byte mutation, forced hash collisions, shared
history, 4,096 differential copies, unchanged tail canaries and the call cap.
The new DLL also passed the frame sentinel in its own private runtime and
rejected unsupported executables and conflicting observer flags. Run the
portable content contract with
`python3 -m unittest discover -s tests -p 'test_bedrock_binding_recurrence.py'`.


The binding observer then completed a nine-second capture in the private
copied world. Nine published threads each reached the 16,384-call cap within
three seconds: 147,456 copies total, all at site0. Of these, 145,881 (98.93%)
matched recent full contents and 145,539 (98.70%) matched the preceding copy.
There were no unexpected sizes, ABI mismatches, exceptions or observed hash
collisions. Site1/site2 did not execute and remain unqualified in gameplay.

The real binding mapping and guarded site0 hook are now exercised. After normal
exit, the separate frame mapping showed 188 registered threads and zero overflow
admissions. These are bounded admitted-thread windows, not an unbiased all-game
reuse rate. All original copies still execute: neither resource ownership nor
safe alias lifetime follows from equal bytes. The observer was disarmed during
performance tests and stopped before save/quit; the normal runtime is unchanged.
