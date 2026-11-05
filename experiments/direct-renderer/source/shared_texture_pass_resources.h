/* CPU-only bounded decoder for one ordered pass's immutable resource graph.
 * Compile implementation with ARC. No Metal objects/commands are created. */
#ifndef FULLFRAME_SHARED_TEXTURE_PASS_RESOURCES_H
#define FULLFRAME_SHARED_TEXTURE_PASS_RESOURCES_H
#import <Foundation/Foundation.h>
#include "vertex_resources.h"

#define FFST_PASS_DRAW_LIMIT 512

typedef void *FFSTPassResources;
typedef struct {
    uint32_t primitive, ia_slot_mask;
    uint64_t start, count, instances, base_instance;
    uint32_t indexed, index_type;
    int32_t base_vertex;
    uint64_t index_count, index_offset;
} FFSTPassDrawInfo;

#ifdef __cplusplus
extern "C" {
#endif
/* Caller retains ownership of directory_fd. It must name an owned private
 * directory (0700); each payload is opened relative to that descriptor with
 * O_NOFOLLOW and must be private, single-linked, regular and owned by this UID.
 * Atomic manifest publication and matching cut_id remain the host's obligation.
 * No filename from JSON is used for lookup: only sequential cut-buffer-%02u.bin
 * and cut-texture-%02u.bin are admitted, with exact declared lengths.
 *
 * Graph: {format:"bedrock-draw-resource-cut",version:2,snapshots:[],textures:[],
 * samplers:[],draws:[{draw:[primitive,start,count,instances,base],ia_slot_mask,
 * bindings:[],vertex_constants:[],fragment_constants:[],arguments:[[],[]],
 * argument_bytes:[N,N], optional indexed:{index_type,base_vertex,index_count,
 * index_offset}, optional index_binding:{id,generation,offset,stride,length}}]}.
 * Version 1 with the same draws[] schema is accepted for authored fixtures.
 * Indexed draw start must be zero and index_count must match draw.count.
 * Snapshot IDs are sequential 1..N, generations nonzero and bindings match them.
 * A null buffer binding is represented by all five integer fields equal zero.
 * Entire graph is rejected on any malformed draw; no partial handle escapes.
 * Global caps follow vertex_resources.h: FF_DRAW_RESOURCE_LIMIT snapshots/
 * FF_VERTEX_BYTES_LIMIT bytes, FF_TEXTURE_RESOURCE_LIMIT textures/
 * FF_TEXTURE_BYTES_LIMIT bytes, FF_SAMPLER_RESOURCE_LIMIT samplers, 256 draws.
 * Retained NSData owns every byte pointer returned below, until destroy. */
FFSTPassResources ffst_pass_resources_load(int directory_fd, NSDictionary *graph);
/* No FD fallback. Reads draw-resource-cut.json from a copied, immutable blob
 * dictionary (64MiB total), then applies the identical graph/asset validation. */
FFSTPassResources ffst_pass_resources_load_blobs(NSDictionary<NSString *,NSData *> *blobs);
/* FFMD1 retained-frame oracle entry: owned snapshots and binary plan/graph. */
FFSTPassResources ffst_pass_resources_load_wire_blobs(NSDictionary<NSString *,NSData *> *blobs);
void ffst_pass_resources_destroy(FFSTPassResources resources);
const ff_vertex_snapshot *ffst_pass_resources_snapshots(FFSTPassResources resources, size_t *count);
/* Exact source byte offset from the validated snapshot row, when present. */
int ffst_pass_resources_snapshot_source_offset(FFSTPassResources resources,size_t index,uint64_t *out);
const ff_texture_snapshot *ffst_pass_resources_textures(FFSTPassResources resources, size_t *count);
const ff_sampler_snapshot *ffst_pass_resources_samplers(FFSTPassResources resources, size_t *count);
size_t ffst_pass_resources_draw_count(FFSTPassResources resources);
/* Draw tuple is validated at load, including bounds, indexed count/alignment,
 * index-buffer coverage and finite draw-work limits. Host compares this tuple
 * to its independently captured ordered pass before GPU submission. */
int ffst_pass_resources_draw_info(FFSTPassResources resources, size_t index, FFSTPassDrawInfo *out);
/* expected is independently reconstructed shader reflection. Checks exact IA
 * mask, constant counts, argument bytes/field counts and each offset/kind pair.
 * out is zeroed on failure. All returned pointers remain owned by resources;
 * global buffers/textures/samplers can be uploaded once for the whole pass. */
int ffst_pass_resources_draw_bindings(FFSTPassResources resources, size_t index,
    const ff_draw_layout *expected, ff_draw_bindings *out);
#ifdef __cplusplus
}
#endif
#endif
