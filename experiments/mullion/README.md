# Isolated Mullion / Bedrock ray tracing

**Minecraft Ray Traced mode works in the isolated proof world on macOS15.3.1
without upgrading. Offscreen mirror reflections, emitter on/off lighting,
AS-build recording and save/reload were verified.**
Read [RESULTS.md](RESULTS.md) for actual observations and limits.

Prepared shortcuts:

- **Run Ray Probe.command**: runs both GPU traversal/readback tests.
- **Launch Bedrock Experiment.command**: verifies both tests, then launches the
  separate Minecraft copy with the limited compatibility profile. It checks the
  cached GPU-readback fingerprints against current files; rerun **Run Ray Probe.command**
  after changing the renderer. The launch shortcut uses the user-requested
  memory-observation override, retaining isolation and the exclusive QA lock.

## Rebuild on this prepared development Mac

The existing standalone Wine build tree/toolchain and owned game are read-only
inputs. This is a source experiment within `1JRobertson/bedrock-mac`, not a
separate project. From this directory:

```sh
python3 stage.py
python3 run.py status
python3 run.py init
python3 run.py build-compat
python3 run.py build-loader
python3 run.py build-probe
python3 run.py shader
python3 run.py inline-shader
python3 run.py inline-probe --compat --relaxed-level
python3 run.py probe --compat --relaxed-level
python3 run.py game-setup --compat --relaxed-level
python3 run.py game --compat --relaxed-level
```

Each build/native action automatically uses the shared QA resource guard. If
another guarded job owns the lock, wait and retry. Do not invoke workers directly.
Close the experimental game before changing its runtime, prefix or settings.
The explicit game-only `--unguarded-game` option records memory without guard
aborts, as requested for the October 21 pressure investigation. It retains the
exclusive QA lock and owned-process cleanup. It is used by the experiment launch
shortcut; the standalone working client and shared guard are unchanged.

`--compat` injects a process-local shim that recognizes Mullion's rejected
internal MSL4.1 library and compiles matching source as MSL3.2. `--relaxed-level`
uses a native loader that supplies aggregate level12_0 while preserving actual
sparse-resource tier0. This is a limited compatibility profile, **not full
FL12_0 conformance**. No newer system API is installed or enabled. Both real
GPU ray tests pass with this combination. See `compat/README.txt`,
`compat/diagnostic-loader.md`, and `compat/sparse-backport-notes.md`.

The corrected GDK native DLL must be named `xgameruntime.dll.threading`.
Its pinned hash is checked before launch. Runtime, prefix DLLs, both shaders,
probe executable and selected modes are covered by the pass fingerprints.

## Test world

Prepared world: **Mullion Ray Proof — Isolated**. It is Creative/Flat, cheats on,
multiplayer off, with both packs activated and Ray Traced mode saved.

For a new test world, create **Creative/Flat**, cheats on, multiplayer off. Activate the
two Ray Proof packs. Use 8 chunks initially and the fixed-camera emitter/mirror
controls in [fixture/README.md](fixture/README.md). Existing saves are never needed.
Verify actual Ray Tracing mode and offscreen reflections/light transport together
with DXR execution evidence. Vibrant Visuals or an enabled toggle is insufficient.

Keep the experimental client on **Simple** or **Ray Traced**. A separate Mullion
texture-view crash occurred in Vibrant Visuals; that path remains unresolved.
If graphics mode buttons are disabled in-world, enable **In-game graphics mode
switching** under main-menu Settings → Video first. The test uses 8 RT chunks
and a 30 FPS limit. Metal HUD measured roughly 28–30 FPS during the initial
automated scene cycles. See [SOAK.md](SOAK.md) for the active-hour stability test
and the distinction between host pressure and application memory growth.

## Isolation and versions

`wine/` independently copies installed WineGDK11.8 bin/lib/share/include using
APFS CoW, with no hard links or escaping runtime symlinks. Mullion is installed
only there. `prefix/` is new; the working bottle and its saves are never copied.
`game/` is a bounded, independent APFS copy of owned game files. Settings, worlds,
fixtures, scripts, logs and launch identity belong to this experiment.

Existing account IPC may be reused, or the existing helper verifies the copied
game through the user's real license. Credentials stay in Keychain; account
trace logging is disabled. Unrecognized sockets are preserved. Owned helper
and Wine processes are cleaned up after the test. Private files are ignored.

Mullion v0.3, commit `5dda0b9af63dd246003a9ee9f84fd738b81867f9`, LGPL2.1-or-later;
Microsoft DXC v1.9.2609. `stage.py` pins archive hashes; `versions.json` records
files and a production baseline. Downloaded packages retain their licenses.

## Checkout and runtime inputs

The default client root is this repository; scripts resolve the current `client/`
layout. If the tested runtime/game/build tree lives in the older development
folder, explicitly set `MULLION_CLIENT_ROOT` to that folder for staging and each
run. That root is a read-only input: all experiment runtime, game copies, worlds
and logs stay under this experiment. Both source layouts are accepted. The
normal launcher does not enable or install this experiment.

`stage.py` also retrieves the exact pinned Mullion shader source commit used by
the MSL fallback. It rejects an existing source checkout at another commit.
The standalone Wine build/toolchain must already exist before loader/probe builds.
No binaries, game files, worlds, screenshots or private logs are in this source
commit. `versions.json` records the original tested developer-layout inputs;
staging a new candidate replaces it with that candidate's fingerprints.

The native measurements in `RESULTS.md` describe the original isolated run. The
repository layout adaptation is checked with offline fixtures; it has not been
separately staged or launched from this public checkout.
