# Research and performance records

These are source-development investigations. Default-off tools live in
[`experiments/`](../../experiments/README.md); detailed records do not establish
what a new packaged app contains or how it performs. Start with
[measurement interpretation](../PERFORMANCE.md) and [release readiness](../RELEASE.md).

## Designs and observations

| Area | Notes | Original measurement record |
| --- | --- | --- |
| DXMT setup and memory lifetime | [Graphics bridge](GRAPHICS.md) | Dated probes in the notes |
| Shared buffers, constants, input layouts | [Buffer experiments](BUFFERS.md) | [Shared buffers](dxmt-shared-buffers-results.json), [packed constants](dxmt-packed-constants-results.json), [input layouts](dxmt-input-layout-results.json) |
| Wine heap reuse and exact-build allocators | [Buffer experiments](BUFFERS.md#wine-small-allocation-reuse-2026-10-05), [allocator experiments](ALLOCATORS.md) | [Heap reuse](wine-heap-reuse-results.json), [refmove](bedrock-refmove-results.json), [render/frame-slab study](render-redesign-results.json) |
| Isolated Bedrock ray tracing | [Mullion experiment](../../experiments/mullion/README.md) | [Actual native results and limits](../../experiments/mullion/RESULTS.md) |
| Presentation pacing and HUD rollback | [Presentation experiments](PRESENTATION.md) | Dated observations in the notes |
| Synthetic ARM communication/batching | [ARM batch study](ARM-BATCH.md) | [Architecture record](m4-architecture-results.json) |

The seven JSON records retain their original bytes, including historical paths
and artifact hashes. Those identifiers describe the measured builds. Use current
source paths in the notes/index when navigating the reorganized repository.

Commands in these notes can build or stage experimental runtimes. They are
reference instructions, not automatic authorization to change an installed game.
Preserve exact rollback files and validate an isolated candidate before any
explicitly authorized staging. Never replace a mapped runtime.
