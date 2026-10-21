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
