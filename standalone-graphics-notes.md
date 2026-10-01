# Standalone graphics

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
