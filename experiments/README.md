# Default-off experiments

These builders/control tools investigate graphics buffers, Wine heap reuse,
exact-game allocators, frame slabs, presentation pacing and metrics overlays.
Ordinary source setup does not enable them. A pinned release profile may
explicitly select reviewed variants; their presence here alone does not mean
they are shipped in an app.

Run reference commands from the project root. Builds write ignored `build/`
outputs. A script with `stage`/`restore` can change a selected runtime only after
explicit authorization, isolated qualification and normal game shutdown.
Exact-game profiles reject other executable hashes; keep matching rollback data.

Start with [the research index](../docs/research/README.md) and
[measurement limits](../docs/PERFORMANCE.md). A synthetic test, CPU-cost reduction
or locally enabled profile does not establish native ARM game support or a
packaged-app FPS gain. The HUD startup crash/rollback remains documented.

## Bedrock ray tracing

[Mullion ray tracing](mullion/README.md) is an isolated, default-off D3D12/DXR
experiment on macOS 15.3.1. The recorded test demonstrated offscreen reflections
and indirect light, about 25 minutes without a fault, and save/restart/reload.
See its [results and limits](mullion/RESULTS.md). It does not change ordinary
startup or claim hours-long stability; Vibrant Visuals has a separate known crash.
