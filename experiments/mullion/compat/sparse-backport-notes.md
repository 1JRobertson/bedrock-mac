# Sparse resources on macOS 15: original design investigation

Historical note written before the successful native ray-tracing world test.
See [current results](../RESULTS.md) for what was subsequently implemented and
verified; the proposed next steps below describe that earlier investigation.

**Current evidence establishes a feature-level gate, not actual Minecraft sparse-resource use.** Do not spend the first attempt implementing a full tiled-resource subsystem.

## What the code and run establish

- `source/src/winemetal/unix/winemetal_unix.c:3225`: `supportsPlacementSparse` returns false before macOS 26.4.
- `source/src/d3d12/d3d12_device.cpp:180`: this leaves `sparse_page_size_ == 0`.
- `d3d12_device.cpp:521`: OPTIONS therefore reports `TiledResourcesTier = NOT_SUPPORTED`.
- `d3d12_device.cpp:469`: the FEATURE_LEVELS aggregate becomes 11_1 only because Tier2 tiled resources are absent; binding tier3, typed UAV extra formats and logic operations are otherwise enabled.
- `source/src/d3d12/d3d12.cpp:82`: D3D12CreateDevice rejects Minecraft's minimum12_0 from that aggregate.
- `logs/game-compat-diagnostic.log`: the opt-in retry gets past device creation. Later `Maximum supported feature level11_1; Using11_1` comes from the D3D11 implementation, followed by a query of `0ec870a6-5d7e-4c22-8cfc-5baae07616ed` (ID3D12CommandQueue) against a D3D11 device and a null read. This is evidence of mixed/fallback backend behavior; it does not establish sparse use.
- No `CreateReservedResource: tiled resources need placement sparse resources` message occurs before that crash. The existing implementation logs this on every reserved-resource attempt when sparse is unavailable.
- A successful independent DXR readback on this OS already establishes that the ray backend itself does not require placement sparse resources.

## Smallest defensible implementation

1. Keep the MSL3.2 internal-library workaround and isolated runtime.
2. Extend only the explicit experimental D3D12 loader path: retry rejected minimum12_0 at11_0 as today, then expose a narrowly scoped **diagnostic aggregate maximum12_0** to FEATURE_LEVELS queries. Leave OPTIONS.TiledResourcesTier at0, preserve real DXR/SM queries and retain the original default behavior without the opt-in flag.
3. Trace creation of actual D3D12 queues/command lists and reserved-resource calls (CreateReservedResource, versions1/2, GetResourceTiling; queue UpdateTileMappings/CopyTileMappings; list CopyTiles). Source-level logs are simplest; a process-local COM-vtable shim is viable if rebuilding d3d12core is expensive. ReservedResource1/2 already delegate to ReservedResource0.
4. Retest title screen and a new tiny ray-test world. If no reserved-resource/tile calls occur, the feature-level bundle was incidental to this game path. Continue rendering fixes without inventing a sparse implementation.
5. If sparse calls occur, record dimensions/format/mips/flags and heap offsets/ranges. Implement only the observed coherent access model, failing explicitly on unsupported aliasing rather than silently ignoring mapping calls.

The aggregate override is deliberately an opt-in diagnostic compatibility quirk, **not full FL12_0 support**. Do not advertise TiledResourcesTier2 or mark general FL12_0 conformance as passed. It is reasonable to test because the missing bundle component need not be used by this application, and all actual API failures remain visible.

## Why old sparse Metal is not a drop-in backport

The installed macOS15 SDK itself provides authoritative declarations:

- `Metal.framework/Headers/MTLHeap.h`: MTLHeapTypeSparse is available since macOS11; `sparsePageSize` since13.
- `MTLDevice.h:1074–1121`: sparse texture tile dimensions/page sizes are available since11/13.
- `MTLResourceStateCommandEncoder.h:69`: `updateTextureMapping:mode:region:mipLevel:slice:` can allocate/free a texture region on its existing sparse heap. There is no physical heap-offset argument.
- `MTLResourceStateCommandEncoder.h:112`: `moveTextureMappingsFromTexture:...` (since13) moves mappings only to an unmapped destination, within the same heap, requiring matching format/type/sample count/usage/options. Moving removes the source mapping; it is not aliasing or non-destructive copying.
- The macOS15 API provides no sparse buffer equivalent. Mullion's newPlacementSparseBuffer and MTL4 queue paths are explicitly macOS26-only.

D3D12 UpdateTileMappings supplies an explicit physical heap tile, can reuse one tile across many virtual regions, can remap between resources, and supports sparse buffers. Old Metal's automatic texture tile allocation cannot faithfully express these contracts. Simply returning true from supportsPlacementSparse would call missing methods and still leave queue mapping as no-ops.

Apple references:
- [Old texture mapping](https://developer.apple.com/documentation/metal/mtlresourcestatecommandencoder/updatetexturemapping(_:mode:region:miplevel:slice:))
- [Placement sparse support](https://developer.apple.com/documentation/metal/mtldevice/supportsplacementsparse?language=objc)
- [Feature tables](https://developer.apple.com/metal/capabilities/)

## Eager committed fallback limits

Replacing CreateReservedResource with CreateCommittedResource alone is not correct. It commits the entire virtual extent, loses heap-tile alias identity, returns incorrect GetResourceTiling results (ordinary textures have reserved_=false), and preserves stale bytes after unmap. Current CopyTiles, mapping tracking and shader residency expect genuine reserved-resource metadata.

A restricted fallback could serve a game that only streams unique texture tiles:

- Allocate ordinary private texture storage under an explicit conservative memory cap; maintain original reserved descriptor and synthetic tile layout.
- Keep CPU page tables mapping logical resource tiles to `(heap, tile)` and per-heap canonical tile content.
- Implement CopyTiles via real tiled buffer/texture copies, map/unmap by clear/copy, and GPU synchronization before reusing heap content.
- Track dirty tiles on UAV/render-target writes; propagate changes to aliases before any subsequent reads. Read-only sampled texture streaming is much easier than arbitrary UAV/render-target aliasing.
- Enforce zero reads/discarded writes and residency reporting for unmapped tiles. Full allocation with zeros alone does not discard writes, and filtered sampling near boundaries needs correct unmapped behavior.
- Reject unsupported REUSE_SINGLE_TILE/aliasing, buffer mappings, compressed/packed-mip layout or write-after-unmap cases until implemented. This restricted implementation must keep advertised tiled tier0; it is not Tier2.

A full Tier2 fallback is substantial shader/memory work and potentially memory-heavy. The current crash contains no evidence justifying it yet. The next concrete goal is proving Minecraft selects its D3D12 backend and measuring which resource APIs it actually invokes.

No native builds, launches or QA were run for this note. No source/runtime files were changed.
