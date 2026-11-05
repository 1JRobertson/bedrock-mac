/* Pre-render GPU snapshot hook for a narrowly qualified ordinary DXMT draw. */
#ifndef FULLFRAME_DRAW_RESOURCE_CUT_H
#define FULLFRAME_DRAW_RESOURCE_CUT_H
#include "shared_snapshot_arena.h"
#import <Metal/Metal.h>
#include "vertex_resources.h"
#include "shader_ia.h"
#include "winemetal.h"
#include <unistd.h>

/* bytesNoCopy requires a page-aligned single VM region. */
static inline int ff_draw_mapped_size(uint64_t length, uint64_t *rounded){
    long page=sysconf(_SC_PAGESIZE);
    if(page<=0||!length||length>UINT64_MAX-((uint64_t)page-1))return 0;
    *rounded=((length+(uint64_t)page-1)/(uint64_t)page)*(uint64_t)page;
    return *rounded<=SIZE_MAX;
}

#define FF_DRAW_FENCE_LIMIT 64
#define FF_DRAW_PASS_LIMIT 512
#define FF_DRAW_CANDIDATE_LIMIT 2048
#define FF_TEXTURE_CANDIDATE_LIMIT 256
enum {
    FF_DRAW_STOP_END, FF_DRAW_STOP_COMMAND, FF_DRAW_STOP_SHADER, FF_DRAW_STOP_RESOURCE,
    FF_DRAW_STOP_WRITE, FF_DRAW_STOP_DRAW_LIMIT, FF_DRAW_STOP_COMMAND_LIMIT, FF_DRAW_STOP_INVOCATIONS
};
enum {
    FF_DRAW_DETAIL_BUFFER_IDENTITY = 1, FF_DRAW_DETAIL_BUFFER_PROVENANCE,
    FF_DRAW_DETAIL_BUFFER_SLICE, FF_DRAW_DETAIL_TEXTURE_PROFILE,
    FF_DRAW_DETAIL_SAMPLER, FF_DRAW_DETAIL_ARGUMENT_TABLE,
    FF_DRAW_DETAIL_BUFFER_CANDIDATES, FF_DRAW_DETAIL_TEXTURE_CANDIDATES,
    FF_DRAW_DETAIL_BUFFER_SNAPSHOTS, FF_DRAW_DETAIL_BUFFER_BYTES,
    FF_DRAW_DETAIL_BUFFER_VERSION, FF_DRAW_DETAIL_TEXTURE_SWIZZLE,
    FF_DRAW_DETAIL_TEXTURE_SNAPSHOTS, FF_DRAW_DETAIL_TEXTURE_BYTES
};
typedef struct {
    const struct wmtcmd_base *command;
    ff_draw_layout layout;
    struct ff_ia_fetch_layout ia_fetch; /* producer-local shader fetch proof */
    uint32_t primitive, instance_count, base_instance, indexed, index_type;
    int32_t base_vertex;
    uint64_t vertex_start, vertex_count, index_offset;
    size_t binding_count;
    ff_vertex_binding bindings[FF_VERTEX_RESOURCE_LIMIT], constants[2][FF_CONSTANT_RESOURCE_LIMIT], index_binding;
    ff_argument_binding arguments[2][FF_SHADER_FIELD_LIMIT];
} ff_draw_plan;
typedef int (*ff_draw_layout_resolver)(id<MTLRenderPipelineState> pipeline,
    const struct wmtcmd_base *command, ff_draw_layout *layout, void *context);
struct ff_draw_cut {
    uint64_t capture_id;
    uint32_t ia_slot_mask;
    uint32_t primitive, instance_count, base_instance;
    uint64_t vertex_start, vertex_count;
    const struct wmtcmd_base *draw_command; /* producer-local, never serialized */
    uint32_t indexed, index_type;
    int32_t base_vertex;
    uint64_t index_offset;
    ff_vertex_binding index_binding;
    ff_draw_layout layout;
    id<MTLFence> ready_fence;
    size_t binding_count, snapshot_count, snapshot_bytes;
    ff_vertex_binding bindings[FF_VERTEX_RESOURCE_LIMIT];
    id<MTLBuffer> snapshots[FF_DRAW_RESOURCE_LIMIT];
    ffsa_extent_desc shared_snapshot_extents[FF_DRAW_RESOURCE_LIMIT]; /* zero for copied fallback */
    uint64_t source_incarnation[FF_DRAW_RESOURCE_LIMIT], source_generation[FF_DRAW_RESOURCE_LIMIT], source_offset[FF_DRAW_RESOURCE_LIMIT];
    uint64_t source_length[FF_DRAW_RESOURCE_LIMIT]; /* aligned captured range; producer-local */
    uint64_t serialized_length[FF_DRAW_RESOURCE_LIMIT]; /* optional post-GPU tail trim */
    /* Private experimental marker state; never serialized as pointers. */
    uint64_t reference_input_version[FF_DRAW_RESOURCE_LIMIT];
    uint64_t reference_source_handle[FF_DRAW_RESOURCE_LIMIT];
    uint64_t reference_stream,reference_frame,reference_chunk,reference_payload;
    size_t serialized_bytes;
    int compacted;
    ff_vertex_binding constants[2][FF_CONSTANT_RESOURCE_LIMIT];
    ff_argument_binding arguments[2][FF_SHADER_FIELD_LIMIT];
    size_t texture_count, sampler_count;
    ff_texture_snapshot textures[FF_TEXTURE_RESOURCE_LIMIT];
    uint64_t source_texture_ids[FF_TEXTURE_RESOURCE_LIMIT]; /* producer-local GPU IDs; never serialized */
    id<MTLBuffer> texture_buffers[FF_TEXTURE_RESOURCE_LIMIT];
    NSMutableDictionary *texture_reuse; /* retained immutable owners; source-only */
    ff_sampler_snapshot samplers[FF_SAMPLER_RESOURCE_LIMIT];
    size_t draw_count;
    ff_draw_plan *draws;
    const struct wmtcmd_base *stop_command;
    int complete_pass;
    int discarded; /* inserted copy remains ordered, but must not be published */
    uint32_t stop_reason, stop_command_type, resource_detail;
    unsigned char direct_eligible[FF_DRAW_RESOURCE_LIMIT],direct_copied[FF_DRAW_RESOURCE_LIMIT];
    void *direct_shadow[FF_DRAW_RESOURCE_LIMIT];
    int direct_cpu_ready;
    NSMutableDictionary *direct_journal; /* ordered owned updates and identity references */
    uint64_t direct_texture_versions[FF_TEXTURE_RESOURCE_LIMIT];
    int direct_pass;
    int staging_gpu_completed; /* local-only tail; all existing offsets unchanged */
};
typedef void (*ff_draw_cut_completion)(struct ff_draw_cut *cut, int gpu_completed, void *context);
typedef int (*ff_draw_cut_filter)(const struct ff_draw_cut *planned, void *context);
/* A coalesced range must retain a single producer reference witness. */
struct ff_draw_source_interval {uint64_t offset,length;};
typedef int (*ff_draw_range_witness)(uint64_t incarnation,uint64_t generation,uint64_t offset,uint64_t length,
    const struct ff_draw_source_interval *parts,size_t part_count,void *context);
/* Return a +1 fresh shared snapshot buffer, or nil to use the ordinary copy.
 * The caller owns the returned buffer. descriptor is zero on fallback. */
typedef id<MTLBuffer> (*ff_draw_snapshot_allocator)(id<MTLDevice>,size_t,
    ffsa_extent_desc *descriptor,void *context);

/* Called BEFORE opening the render encoder. The caller must establish all of:
 * - same DXMT command stream/queue; initializer and cross-queue waits already
 *   encoded; all relevant pre-raster dependency fences supplied here;
 * - exact IA slot mask for this pipeline's captured shader variant;
 * - the argument buffer's CPU bytes are immutable until this command completes;
 * - first ordinary draw is the intended draw and all its non-vertex inputs,
 *   shader writes, attachments and state are independently qualified.
 * Private buffers are accepted directly. Managed/shared buffers require paired
 * DXMT allocation identity, rename generation and logical suballocation bounds.
 * Dynamic CPU writes must honor D3D11's in-flight NO_OVERWRITE read lifetime;
 * other suballocations are excluded. Shader-read bytes, constant tables,
 * indices and sampled texture views are copied before the selected first draw.
 * It does not suppress the original draw. A nonzero result means completion is
 * delivered exactly once after the command buffer completes; caller must then
 * destroy the cut. The returned ready_fence must be waited by every subsequent
 * render stage before it can access an untracked source allocation. The returned
 * scheduled pointer is borrowed until completion; completion owns destruction.
 * Zero means rejected and no callback or cut. */
int ff_draw_cut_schedule(id<MTLCommandBuffer> command, const struct wmtcmd_base *head,
    id<MTLBuffer> initial_argument_buffer, const ff_draw_layout *layout,
    const id<MTLFence> *fences, size_t fence_count,
    ff_draw_cut_completion completion, void *context, struct ff_draw_cut **scheduled);
void ff_draw_cut_destroy(struct ff_draw_cut *cut);
/* Call only after successful GPU completion. Fresh captured indices and exact
 * IA provenance may trim unused tails; every other use keeps its full range.
 * Origins and all draw/index values remain unchanged. Idempotent. */
int ff_draw_cut_compact(struct ff_draw_cut *cut);
/* Experimental continuous stream: temporary GPU staging is bounded separately
 * from the unchanged 32 MiB serialized/native graph limit. */
#define FF_DRAW_STAGING_BYTES_LIMIT (40u * 1024u * 1024u)
int ff_draw_cut_compact_for_wire(struct ff_draw_cut *cut, int gpu_completed);
/* Own one resource graph for an ordered, compatible prefix of a render pass.
 * All inputs are read-only over that prefix. Unsupported state, a shader write,
 * resource bounds or the draw limit stop before the first unsupported command;
 * no command is skipped. At least one supported draw is required. Each draw's
 * binding IDs refer to the same snapshots/textures/samplers on the returned cut.
 * Single-draw legacy fields mirror draws[0]. Completion/lifetime/fence rules
 * are identical to ff_draw_cut_schedule. Resolver runs synchronously only. */
int ff_draw_pass_cut_schedule(id<MTLCommandBuffer> command, const struct wmtcmd_base *head,
    id<MTLBuffer> initial_argument_buffer, ff_draw_layout_resolver resolver, void *resolver_context,
    const id<MTLFence> *fences, size_t fence_count, size_t draw_limit,
    ff_draw_cut_completion completion, void *context, struct ff_draw_cut **scheduled);
/* Filter runs after all prefix metadata is known, before allocating staging or
 * inserting GPU work. Snapshot byte pointers are not available at this point.
 * Returning zero leaves the command buffer untouched and invokes no completion. */
int ff_draw_pass_cut_schedule_checked(id<MTLCommandBuffer> command, const struct wmtcmd_base *head,
    id<MTLBuffer> initial_argument_buffer, ff_draw_layout_resolver resolver, void *resolver_context,
    const id<MTLFence> *fences, size_t fence_count, size_t draw_limit,
    ff_draw_cut_filter filter, void *filter_context,
    ff_draw_cut_completion completion, void *context, struct ff_draw_cut **scheduled);
int ff_draw_pass_cut_schedule_checked_with_allocator(id<MTLCommandBuffer> command, const struct wmtcmd_base *head,
    id<MTLBuffer> initial_argument_buffer, ff_draw_layout_resolver resolver, void *resolver_context,
    const id<MTLFence> *fences, size_t fence_count, size_t draw_limit,
    ff_draw_cut_filter filter, void *filter_context,ff_draw_snapshot_allocator allocator,void *allocator_context,
    ff_draw_cut_completion completion, void *context, struct ff_draw_cut **scheduled);
int ff_draw_pass_cut_schedule_checked_with_allocator_witness(id<MTLCommandBuffer> command, const struct wmtcmd_base *head,
    id<MTLBuffer> initial_argument_buffer, ff_draw_layout_resolver resolver, void *resolver_context,
    const id<MTLFence> *fences, size_t fence_count, size_t draw_limit,
    ff_draw_cut_filter filter, void *filter_context,ff_draw_snapshot_allocator allocator,void *allocator_context,
    ff_draw_range_witness witness,void *witness_context,
    ff_draw_cut_completion completion, void *context, struct ff_draw_cut **scheduled);
int ff_draw_pass_cut_schedule_bounded_staging(id<MTLCommandBuffer> command, const struct wmtcmd_base *head,
    id<MTLBuffer> initial_argument_buffer, ff_draw_layout_resolver resolver, void *resolver_context,
    const id<MTLFence> *fences, size_t fence_count, size_t draw_limit,
    ff_draw_cut_filter filter, void *filter_context,ff_draw_snapshot_allocator allocator,void *allocator_context,
    ff_draw_cut_completion completion, void *context, struct ff_draw_cut **scheduled);
int ff_draw_pass_cut_schedule_bounded_staging_witness(id<MTLCommandBuffer> command, const struct wmtcmd_base *head,
    id<MTLBuffer> initial_argument_buffer, ff_draw_layout_resolver resolver, void *resolver_context,
    const id<MTLFence> *fences, size_t fence_count, size_t draw_limit,
    ff_draw_cut_filter filter, void *filter_context, ff_draw_snapshot_allocator allocator, void *allocator_context,
    ff_draw_range_witness witness, void *witness_context,
    ff_draw_cut_completion completion, void *context, struct ff_draw_cut **scheduled);
#endif
