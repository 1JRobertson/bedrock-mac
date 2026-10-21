# Buffer and input-layout experiments

Historical development notes. These commands and observations refer to the
source runtime described in each entry. They do not establish a packaged-app
result or authorize staging into an active installation. See the
[research index](README.md) and [current release gates](../RELEASE.md).

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
reused unchanged. `docs/research/dxmt-shared-buffers-results.json` preserves the measurements.
`tests/dxmt-shared-buffers.cpp` tests 32,768 queued constant-buffer updates with GPU
readbacks across allocation reuse; the original and optimized builds both passed.

Build and deploy (close the target game first):

```sh
python3 experiments/standalone-dxmt-shared.py build
python3 experiments/standalone-dxmt-shared.py stage
```

The builder uses the locally installed LLVM MinGW and Meson tools under
`build/performance` by default; `--toolchain` and `--python` accept alternative
locations. It pins DXMT's source revision, initializes its pinned submodules, and
checks the upstream archive and embedded shader hashes. Artifacts and provenance
are saved under `build/dxmt-shared-buffers`. Staging backs up both the previous DLL
and its manifest, updates both runtime copies, and verifies their checksums.
The original graphics release can be restored with:

```sh
python3 experiments/standalone-dxmt-shared.py restore
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
`docs/research/dxmt-packed-constants-results.json`.

Packing with default CPU cache reduced CPU work but lowered throughput 3–7%, so the
selected build combines packing with write-combined cache. An additional shortcut
for UpdateSubresource showed no material throughput gain and was excluded.
The production patch includes no profiling counters, file polling, experimental
pool switching, or update shortcut.

Build and stage this separate profile with the game closed:

```sh
python3 experiments/standalone-dxmt-shared.py build --packed-constants
python3 experiments/standalone-dxmt-shared.py stage --packed-constants
```

Artifacts are in `build/dxmt-packed-constants`. The profile keeps an independent
backup of the previously installed DLL and DXMT manifest, preserving the original
shared-buffer profile and its upstream backup. Roll back this second optimization:

```sh
python3 experiments/standalone-dxmt-shared.py restore --packed-constants
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
`docs/research/wine-heap-reuse-results.json`.

The candidate and matching source control passed 2,398,208 allocation/free pairs,
8,192 reallocations, dirty/zero reuse, boundary sizes, private heaps and
cross-thread frees. Eight staging/rollback fixture tests passed. A separate
isolated rebuild passed with identical recorded source inputs; embedded build
paths change binary data addresses, so it is not byte-identical.

Build and explicitly stage this optional profile with the target game closed:

```sh
python3 experiments/standalone-wine-heap.py build
python3 experiments/standalone-wine-heap.py stage --wine runtime/standalone/wine
```

The artifact and provenance live in `build/wine-heap-reuse`. Staging changes only
the Windows `ntdll.dll` and its runtime metadata, with checked backups of both.
The standard Wine builder does not automatically apply this experimental patch.
Restore the exact previous DLL and runtime manifest with:

```sh
python3 experiments/standalone-wine-heap.py restore --wine runtime/standalone/wine
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
deployment status are in `docs/research/dxmt-input-layout-results.json`.

`tests/dxmt-input-layout.cpp` passed 31 GPU readback cases and seven state checks
with the diagnostic shortcut disabled and enabled, then with the clean release
build. Cases cover repeated/changed/null layouts, shader changes, render-target
format, blend/sample-mask/topology changes, depth-only rendering, ClearState,
and deferred command replay with context restoration enabled and disabled.
The release DLL contains no frontend profiling, timers or control-file polling.

Build and stage the separate profile with the target game closed:

```sh
python3 experiments/standalone-dxmt-shared.py build --reuse-input-layout
python3 experiments/standalone-dxmt-shared.py stage --reuse-input-layout
```

This includes the existing shared-buffer and packed-constant patches. Its
independent backup preserves the previous packed graphics DLL and exact DXMT
manifest. Restore that previous graphics build with:

```sh
python3 experiments/standalone-dxmt-shared.py restore --reuse-input-layout
```

Heap reuse is independent and remains installed when this graphics profile is
restored. Source attribution and license notices are in `THIRD_PARTY.md`.
