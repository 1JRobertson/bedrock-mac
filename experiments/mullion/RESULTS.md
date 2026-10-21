# Results — October 21, 2026

**Minecraft ray tracing is verified in the isolated proof world on macOS15.3.1,
without upgrading.** Ray Traced mode renders the offscreen emitter pattern in
the mirror and colored room lighting. Emitter off/on controls and save/reload
pass. Selected working-client checksums remain unchanged.

## Environment

M4 Pro Mac mini, 16 GPU cores, 24 GB RAM, macOS 15.3.1 (24D70). Display:
1920×1080/100 Hz. Owned Minecraft Windows 1.26.5203.0, independent APFS copy;
fresh prefix, no production saves copied. Independent WineGDK 11.8 runtime;
Mullion v0.3 (`5dda0b9af63dd246003a9ee9f84fd738b81867f9`); DXC v1.9.2609.
Exact hashes are in `versions.json`. Native tests/builds ran serially through
the repository QA resource guard. No containers or OS upgrades were used.

## Observations

| Test | Actual result |
| --- | --- |
| Stock Mullion device creation | Aborts: embedded internal command library uses unsupported Metal language 4.1 |
| Process-local MSL3.2 fallback | Recompiles only the recognized internal library; D3D12 device succeeds |
| Stock FL12_1/12_0 minimum | Rejected on this OS; earlier client falls back to D3D11 |
| Retry at FL11_0 alone | Device succeeds, but it does not keep Minecraft on D3D12 |
| Initial game crash | Fault maps to WineGDK `XTaskQueueDispatch+0x17`; experiment's native threading DLL had the wrong filename |
| Threading fix | Installs `system32/xgameruntime.dll.threading` with pinned hash and verifies it before launch; previous immediate crash disappears |
| Limited FL12_0 profile | Changes aggregate maximum to 12_0 while preserving actual tiled-resource tier 0; client enters D3D12 and stays alive beyond the prior crash |
| Pipeline DXR | Real BLAS/TLAS, `TraceRay`/`DispatchRays`, fenced GPU readback: **1,152 hits, 2,944 misses, 0 wrong pixels** |
| Inline DXR | SM6.5 compute `TraceRayInline`/`Proceed`/`CommittedStatus`, fenced GPU readback: **1,152 hits, 2,944 misses, 0 wrong pixels** |
| Native presentation probe | D3D11 device/swapchain, red-pixel GPU readback and Present succeed |
| Minecraft renderer selection | Actual loaded modules show D3D12Core and the correctly named native GDK threading DLL; no D3D11 DLL in corrected profile runs |
| Minecraft world/RT scene | Ray Traced mode selected; red L and blue bar behind the camera appear in the iron mirror; colored light reaches the room |
| Emitter controls | Removing rear emitters darkens mirror and room; restoring them restores reflections and lighting |
| Actual Minecraft DXR work | Instrumented command lists record BLAS/TLAS builds (logged counts reach 8,192+); no direct DispatchRays calls recorded |
| Save/reload | Proof world saves and reloads with Ray Traced mode and correct lighting |
| Vibrant Visuals crash | Opening chat after initial world entry faults in Mullion `TextureView::incRef`, `d3d12core.dll+0xcc790`, null read at `0x38`; unresolved. Simple and Ray Traced paths worked in the successful run |
| Resource limits during retry | Two subsequent launches stopped by the resource guard at memory pressure level 2; other processes preserved |

Both ray modes compare every one of 4,096 GPU pixels against CPU triangle
geometry, including hit and miss cases. Pipeline readback (private capture `evidence/triangle.png`).
These are genuine GPU traversal tests, not feature-bit/toggle checks, but they
are independent of Minecraft. The later native world tests below establish the
Minecraft result. The later October 21 stability section records measured FPS and a 25-minute session; hours-long stability remains unverified.
The crash sample measured about 703 MiB physical footprint, 1.3 GiB peak; these
are startup measurements, not gameplay memory results.

## Why an upgrade is avoidable for this experiment

[The native bridge](https://github.com/dttdrv/mullion/blob/v0.3/src/winemetal/unix/winemetal_unix.c#L3225)
exposes placement sparse memory only inside `@available(macOS 26.4, *)`.
Without it, the device reports tiled-resource tier 0, and its
[aggregate feature-level calculation](https://github.com/dttdrv/mullion/blob/v0.3/src/d3d12/d3d12_device.cpp#L457)
limits the stock device to FL11_1. This is not a hardware ray-tracing requirement.

`--relaxed-level` supplies a limited aggregate 12_0 profile while keeping the
individual sparse tier at 0. It does **not** implement tile aliasing or sparse
buffers and is **not a conformant full FL12_0 implementation**. No reserved-resource
requests were observed during the tested startup. World workloads may require
additional unsupported features. See `compat/sparse-backport-notes.md`.

The original crash was a separate setup error I introduced: the helper DLL was
copied as `xgameruntime.dll` instead of `xgameruntime.dll.threading`. Correcting
that filename matches the working launcher's setup. Earlier conclusions that
the crash itself blocked a no-upgrade solution were premature.

The loader records bounded CPU-side AS builds/ray dispatch calls. Those logs
show command recording, not completed GPU work or a game ray-traced frame.
Zero counters cannot exclude indirect dispatch or stripped inline shaders.

## Reproduce and inspect

Use `README.md` for complete setup. The prepared experiment can be launched with
**Launch Bedrock Experiment.command**; **Run Ray Probe.command** runs both GPU tests.
All game launches require both pass fingerprints to match current files/options.
The separate test packs and fixed-camera commands are in `fixture/README.md`.

Important private evidence:

- `logs/inline-probe-compat-relaxed.log` and `logs/probe-compat-relaxed.log`.
- `logs/game-compat-relaxed.log`: corrected native D3D12 launch and recorded commands.
- `logs/sessions/`: preserved earlier failing and corrected launch logs.
- `logs/relaxed-game-vmmap.txt`: original fault's module mapping.
- `logs/native-live.sample.txt`: corrected process's native run loop/thread sample.
- `logs/final-audit.json`: final selected-file checksum and cleanup audit.

The loader and native-library workaround remain confined to the experiment.
Without an experimental native override, normal Wine uses its stock loader.
No production game process was launched. Selected hashes of the working launcher,
Wine loader, D3D11 DLL and Metal bridge match the original baseline. No production
world/add-on staging steps occur in the experiment's scripts.

## Native world evidence

World **Mullion Ray Proof — Isolated** (`Sx1IMyGs2aY=`) belongs only to the
experimental prefix. Creative/Flat, multiplayer off, cheats on; both proof packs
active. In-game graphics mode switching enabled in the main menu; **Ray Traced**
selected in-world (`graphics_mode:3`). 8 RT chunks, 30 FPS cap, 1686×953 game area.
The successful live run stayed responsive for several minutes, including chat
commands and save/reload, with no new crash signatures. This is a short test,
not a broad game-compatibility or long-session stability result.

- Selected mode (private capture `evidence/rt-mode-selected.jpg`).
- Mirror and lights on (private capture `evidence/rt-room-on.jpg`).
- Emitters removed (private capture `evidence/rt-room-off.jpg`).
- Rear-facing source geometry (private capture `evidence/rt-room-rear-sources.jpg`).
- Reloaded world (private capture `evidence/rt-room-reloaded.jpg`).

The rear control reverses the asymmetric pattern relative to its mirror image.
The emitters remain behind the north-facing camera. Removing them makes both
their mirror images and colored room illumination disappear. In a matched floor
region, mean RGB changed from approximately (89.5,10.2,106.7) to (16.0,14.8,15.0).
These visuals, the selected Ray Traced mode and Minecraft's AS-build recording
jointly establish the native result. CPU recording logs alone do not establish
GPU execution; no direct DispatchRays method calls were observed.

Private `logs/world-rt-evidence.json` records settings, process observation,
selected production hashes and the guard snapshot. The initial short-test experimental client was
left open for the user under the memory guard; the later stability session used
the explicit game-only override described below. Close it before running another
experiment shortcut; the guard retains the shared native-QA lock while it runs.


## October 21 experimental-use stability session

The game-only memory-guard override was explicitly requested by the user. The
shared guard and working client were unchanged; the exclusive QA lock and owned
process cleanup stayed active. Host pressure level 2 did not terminate this run.

- **29,516 active cycle ticks**, approximately **24.6 minutes at 20 TPS**. The
  recorded render interval was **25.2 minutes**, including final scene controls.
  The user asked whether further testing was necessary; the run was concluded
  as sufficient for experimental use. **The 72,000-tick hour target was not completed.**
- **42,339 recorded frame intervals**, about **27.98 FPS average**. Recent active
  scene intervals were near 30 FPS; median GPU time was **30.06 ms**.
- Minecraft's inactivity overlay appeared around minute 16 and reduced
  presentation to roughly 10 FPS. Simulation continued. Dismissing it restored
  approximately 30 FPS. This interval is included in the average above.
- Metal HUD process footprint: **4,395 → 4,631 MiB**, peak **4,635 MiB**.
  Graphics allocations: **2,804 → 3,135 MiB**, peak **3,139 MiB**. Allocations
  decreased on some scene cycles, but modest net growth remained. This does
  not prove the absence of a slow leak or establish an overnight memory plateau.
- No application/GPU fault signature occurred. Lights, camera orientation and
  remote flat-world areas cycled; the final lit mirror was restored. World save
  and normal application exit succeeded (**exit 0**).
- The unsuccessful advertised-DXGI-budget experiment was removed: lowering that
  value did not meaningfully lower actual gameplay memory. Both real GPU probes
  passed again with zero wrong pixels after restoring the original shim.

Private session evidence: `logs/soak/20261021-091207/` contains `start.json`,
`end.json`, `performance.json`, archived game/host-memory logs, process samples,
allocation snapshots and scene/scoreboard captures. `SOAK.md` describes the test.
The prepared experiment launch shortcut checks matching GPU-test fingerprints,
then uses the explicitly requested game-only memory-observation override.

Post-session full client restart and world reload passed: the mirror pattern and
colored indirect lighting returned at approximately 30 FPS. The experimental
client was left open in the proof world. Pause-on-focus-loss was restored to 1.
The four selected working-client hashes and both GPU probe fingerprints matched.

These observations were recorded in the surrounding development directory.
The source-only copy in this repository adapts client-script paths to the current
layout and adds pinned shader-source acquisition. Offline checks cover that
adaptation; no new native run of this checkout is claimed. Private evidence
remains in the original isolated experiment and is intentionally not exported.
