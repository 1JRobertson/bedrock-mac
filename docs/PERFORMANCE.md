# Performance evidence

The release candidate has **no verified end-to-end FPS speedup yet**. Historical
experiments measured specific development runtimes, scenes and instruments.
They help explain engineering choices; they do not predict performance on every
Mac or establish which changes are in a new app bundle.

## Read the measurements correctly

| Measurement | What it means | What it does not prove |
| --- | --- | --- |
| Displayed FPS / presentation intervals | Completed display presentations over a stated interval, when measured with actual presentation callbacks | Submission rate or general performance in other scenes |
| Submission / encoder throughput | Work produced by part of the render pipeline | Frames actually shown to the player |
| Aggregate CPU milliseconds per displayed frame | Sum of measured process CPU time divided by displayed frames | Wall-clock frame time, single-core latency, watts or battery life |
| Process footprint | Memory in the measured processes during that interval | Leak freedom or overnight stability |
| Synthetic ARM batch timing | Kernel plus the specified communication cost in a standalone experiment | Native game execution or game FPS |

An optimization tested on top of earlier changes has a different baseline.
Do not add or multiply those percentage improvements into a cumulative claim.
A capped frame rate can stay unchanged while CPU cost falls. Even a CPU reduction
does not establish lower energy use without a separate power/energy measurement.

## Original records

Keep these records and raw evidence unchanged:

- [Shared buffers](dxmt-shared-buffers-results.json)
- [Packed constants](dxmt-packed-constants-results.json)
- [Input-layout reuse](dxmt-input-layout-results.json)
- [Wine heap reuse](wine-heap-reuse-results.json)
- [Refmove](bedrock-refmove-results.json)
- [Render redesign / frame slab](render-redesign-results.json)
- [Synthetic M4 architecture study](m4-architecture-results.json)
- [Detailed graphics notes](../standalone-graphics-notes.md)

For example, the October 7 instrumented OFF/16/OFF/16/OFF frame-slab observation
reported lower aggregate CPU cost per displayed frame with essentially unchanged
FPS. Its OFF state still included instrumentation; separate normal-module runs
had cross-launch variation. Neither establishes a precise candidate-wide benefit.

## A publishable comparison

Compare one hash-identified original runtime with one hash-identified candidate
on the same Mac, game version, copied world, camera and graphics settings.
Record resolution, render/simulation distances, frame cap, refresh rate, power
mode, foreground state, warm-up and run durations. Use repeated paired runs in
a declared order without competing games/builds. Retain every valid run and
predeclare exclusions. Report displayed-frame intervals, CPU cost and footprint
separately, plus crashes or save failures. Run on the M1 separately before making
an M1 claim. If a fair original cannot be reconstructed, report candidate-only
measurements instead of inventing a baseline.
