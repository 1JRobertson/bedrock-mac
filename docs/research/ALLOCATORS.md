# Exact-build allocator experiments

Historical development notes. These commands and observations refer to the
source runtime described in each entry. They do not establish a packaged-app
result or authorize staging into an active installation. See the
[research index](README.md) and [current release gates](../RELEASE.md).

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
`docs/research/bedrock-refmove-results.json`. These are actual Metal display timestamps,
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
python3 experiments/standalone-bedrock-refmove.py stage --wine runtime/standalone/wine --enable
```

Restore this overlay before restoring the older heap profile:

```sh
python3 experiments/standalone-bedrock-refmove.py restore --wine runtime/standalone/wine
```

Staging journals the previous DLL and runtime manifest and refuses active or
mismatched runtimes. The source export includes the helper, patch, and fixture
tests, not compiled Wine or game binaries. `build` writes separate review
artifacts; it does not promote a new compiler output into the frozen tested
artifact. A new binary requires its own validation before use.


## October 6: render-allocation candidates

The next experiments target repeated ownership and allocation work while keeping
graphics settings unchanged. They use a copied runtime, prefix and world. The
normal runtime is not changed by the build commands below.

`python3 experiments/standalone-dxmt-shared.py build --borrow-constant-buffers` builds a
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
`python3 experiments/standalone-bedrock-allocator.py build --source <pinned-standalone-wine-source>
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

The larger candidate is built by `experiments/standalone-bedrock-frame-slab.py build` using
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
python3 experiments/standalone-bedrock-frame-control.py build
python3 experiments/standalone-bedrock-frame-control.py set --control <capture> --chunk-kib 16
python3 experiments/standalone-bedrock-frame-control.py status --control <capture>
# Only after the test game has exited:
python3 experiments/standalone-bedrock-frame-control.py decode --control <capture>
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
python3 experiments/standalone-bedrock-frame-profile.py stage \
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
python3 experiments/standalone-bedrock-frame-profile.py restore \
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
`client/Launch Standalone.command` subsequently loaded `24f230a1…` and logged the
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
in [render-redesign-results.json](render-redesign-results.json).
