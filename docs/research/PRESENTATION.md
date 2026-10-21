# Presentation and HUD experiments

Historical development notes. These commands and observations refer to the
source runtime described in each entry. They do not establish a packaged-app
result or authorize staging into an active installation. See the
[research index](README.md) and [current release gates](../RELEASE.md).

## October 6: display-paced presentation queue

The normal standalone launcher now enables the locally built presentation-feedback renderer through a hash-checked `runtime/standalone/wine/frame-pacing.json` stage. The native bridge enables Metal display sync and bounds pending presentations to two per layer (50 ms bounded wait when the display stops delivering callbacks). D3D command-queue latency is capped at one; the additional duration limiter stays disabled. Graphics quality, resolution and 48-chunk render distance remain unchanged; the earlier VSync-off game option remains in place.

The clean build reuses the release objects containing shared buffers, packed constants and input-layout reuse. The native bridge retains the existing ColorSync and autorelease fixes. Presentation tracing is optional and off in normal launches. No experimental CPU timer or two-drawable override is included.

Validation: both graphics/readback probes passed on the exact staged binaries. A 30-second title capture measured 99.62 presentations/s, p99 9.9915 ms, one 49.96 ms interval and no intervals above 50 ms. Median submission-to-presentation time fell from 28.88 ms in the earlier 100 FPS baseline to 19.34 ms. A 30-second loaded-world capture measured 95.59 presentations/s, p99 19.9827 ms and maximum 19.9828 ms, with no intervals above 33 ms. All callbacks in those windows were positive, with a single 1683x951 layer and no capture issues. These are presentation measurements, not physical input-to-photon measurements or a guarantee against all future hitches.

Loading still includes separate CPU-side pauses before Present (537 ms in a traced reload). This change does not claim to remove those stalls. The original user world was not used for diagnostic edits.

Rebuild: `python3 experiments/build-standalone-frame-pacing.py`. Evidence: `build/dxmt-frame-pacing/render-validation.json` and `build/performance/stutter-20261006/{menu-release-feedback2,world-release-feedback2}.json`. Staging backup: `runtime/standalone/wine/frame-pacing-backups/20261006-105350`; `restore.json` maps every replaced runtime/prefix file to its backup. To disable this stage at the next launch, set `enabled` to false in `frame-pacing.json`; retain the binaries or restore all recorded files while the game is closed.

## October 6: metrics overlay

The HUD candidate adds a 276×154 point native layer, inset 18 points from the game viewport’s top right. It follows resizing/fullscreen and has no input surface; F8 toggles its visibility. It shows actual distinct Metal presentation timestamps as a two-second rolling FPS/mean frame interval, a recent frame-time graph, this game process’s CPU share of all active cores, and physical memory footprint in GiB. Empty/occluded presentation windows show a dash instead of fabricated FPS. The overlay redraws twice per second, keeps a bounded 512-sample ring, and writes no per-frame logs. Native frame pacing is preserved.

Source: `experiments/standalone-metrics-hud.m` and `.h`; builder: `experiments/build-standalone-metrics-hud.py`; local output and stage script: `build/metrics-hud/`. The exact bridge passed GPU, texture, and discard readback probes; its top-right placement was visually checked in a window and fullscreen, and F8 hiding was checked. A presentation-overhead capture was interrupted by screen changes and rejected; no numerical overhead improvement or zero-cost claim is made.

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
