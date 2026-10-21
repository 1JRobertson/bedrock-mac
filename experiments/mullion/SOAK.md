# Experimental ray-tracing stability test

Run only in **Mullion Ray Proof — Isolated**. The source functions are in
`fixture/behavior_pack/functions/rayproof/soak_*.mcfunction`. Build and stage
only while the experimental game is closed; back up that world first.

Enable Ray Traced mode, 8 RT chunks and a 30 FPS cap. For unattended testing,
set `pause_menu_on_focus_lost:0` only in the experimental profile. Restore it
when the test finishes. Never change the working profile.

Start in chat with `/function rayproof/soak_start`. It counts **72,000 active
simulation ticks**, about an hour at 20 TPS. Paused time does not count. Every
three-minute cycle turns the rear emitters off/on, rotates the camera, visits
two flat-world areas at ±512 blocks, and returns to the mirror. Completion
removes the active tag and restores the lit room. Stop early with
`/function rayproof/soak_stop`.

The scoreboard/actionbar counter establishes simulation progress. It is not a
GPU frame counter. Pair it with Metal presentation telemetry and scene captures.
A process staying alive, or a paused window, does not constitute a passing run.
Minecraft's inactivity overlay appeared after approximately 15 minutes without
physical input, reducing presentation to about 10 FPS while simulation continued.
Dismiss it and send occasional gameplay input during an active-rendering test;
record the interval rather than treating it as a renderer fault. Held keypresses
of 100–200 ms were more reliable than instantaneous keypresses through Wine.
After completion verify reflections and indirect light, save/reload, and audit
the four selected working-client checksums in `versions.json`.

Launch through `run.py game --compat --relaxed-level` under its normal memory
guard. For the explicitly user-authorized pressure investigation, append
`--unguarded-game`: this bypasses memory refusal/termination for this game only,
retains the shared exclusive QA lock and normal owned-process cleanup, and
records host pressure/swap in `logs/game-host-memory.ndjson`. It does not change
the shared guard or working client. The experimental launch shortcut uses this
override. Optionally prefix the command with `MTL_HUD_ENABLED=1`,
`MTL_HUD_LOG_ENABLED=1` and `MTL_HUD_LOGGING_ENABLED=1`; the last spelling supports
older HUD versions. The [Apple Metal HUD documentation](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance)
describes the presentation intervals, GPU times and memory telemetry.
`soak_watch.py --pid PID --minutes 85` observes the existing isolated game and
writes private process/memory samples. It validates the exact experiment path
and process creation identity, cleans up only its own log reader, and never
launches or stops Minecraft. Its wall-clock window alone never implies PASS.

Host memory-pressure interruption and application faults are separate outcomes.
The game-only override above follows the user's explicit October 21 request.
Do not terminate unrelated apps or call interrupted time a stability pass.
Preserve diagnostic logs before retrying. Elevated host pressure alone does not
establish a leak: compare game memory across repeated identical scene cycles.
