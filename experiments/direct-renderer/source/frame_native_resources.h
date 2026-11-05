#ifndef BEDROCK_FRAME_NATIVE_RESOURCES_H
#define BEDROCK_FRAME_NATIVE_RESOURCES_H
#import "vertex_resources.h"

/* Native-only retained objects. These are never serialized onto frame_stream.
 * The frame controller proves root/view/generation/content identity before
 * mapping a logical reference to this pass-local snapshot ID. */
typedef struct {
    uint64_t snapshot_id;
    id<MTLTexture> texture;
} ff_native_texture_override;
typedef struct {
    uint64_t snapshot_id;
    id<MTLBuffer> buffer;
    uint64_t base_offset;
} ff_native_buffer_override;

#ifdef __cplusplus
extern "C" {
#endif
/* Optional overrides must be unique valid snapshot IDs on this exact device.
 * Descriptor, physical face/mip count and swizzle must match the metadata.
 * Overridden entries may have bytes=NULL; no CPU image is uploaded for them.
 * The returned graph retains all supplied objects through its child draws. */
ff_vertex_resources *ff_vertex_resources_create_graph_native(
    id<MTLDevice> device, const ff_vertex_snapshot *snapshots, size_t snapshot_count,
    const ff_texture_snapshot *textures, size_t texture_count,
    const ff_sampler_snapshot *samplers, size_t sampler_count,
    const ff_native_texture_override *overrides, size_t override_count);
/* Buffer overrides retain the prior native copy output. base_offset locates
 * this snapshot's logical slice in the shared native allocation; IA/constant/
 * argument pointers and index offsets all include it. NULL CPU bytes allowed. */
ff_vertex_resources *ff_vertex_resources_create_graph_native_assets(
    id<MTLDevice> device, const ff_vertex_snapshot *snapshots, size_t snapshot_count,
    const ff_texture_snapshot *textures, size_t texture_count,
    const ff_sampler_snapshot *samplers, size_t sampler_count,
    const ff_native_buffer_override *buffers, size_t buffer_count,
    const ff_native_texture_override *textures_native, size_t texture_native_count);

/* Native pass-local tables. The graph was validated/retained once by its graph
 * constructor. This batch checks every draw's generation/ranges/relocations,
 * then snapshots its small tables into one immutable Metal buffer. No caller
 * binding or metadata pointer is borrowed after construction.
 * Success transfers graph ownership; failure leaves it with the caller.
 * max_bytes bounds actual arena.allocatedSize, including driver rounding.
 * Legacy shared-draw ownership/binding APIs are unchanged. */
#define FF_NATIVE_PASS_DRAW_LIMIT 512u
typedef struct ff_vertex_pass_resources ff_vertex_pass_resources;
ff_vertex_pass_resources *ff_vertex_pass_resources_create(ff_vertex_resources *graph,
    const ff_draw_bindings *draws,size_t count,uint64_t max_bytes);
uint64_t ff_vertex_pass_resources_allocated_bytes(const ff_vertex_pass_resources *pass);
/* Declare the exact union of the legacy draws' read/stage declarations once
 * per target encoder, immediately before its first draw. Resources are retained
 * by the pass through actual GPU completion, not by useResources itself. */
void ff_vertex_pass_resources_declare(ff_vertex_pass_resources *pass,id<MTLRenderCommandEncoder> encoder);
void ff_vertex_pass_resources_bind(ff_vertex_pass_resources *pass,size_t draw,id<MTLRenderCommandEncoder> encoder);
id<MTLBuffer> ff_vertex_pass_resources_index(ff_vertex_pass_resources *pass,size_t draw,NSUInteger *offset);
void ff_vertex_pass_resources_destroy(ff_vertex_pass_resources *pass);
#ifdef __cplusplus
}
#endif
#endif
