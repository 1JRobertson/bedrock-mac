/* Native reconstruction of DXMT's ordinary-pipeline vertex-pulling table.
 * Only use snapshots captured coherently at the selected draw's execution cut. */
#ifndef FULLFRAME_VERTEX_RESOURCES_H
#define FULLFRAME_VERTEX_RESOURCES_H
#import <Metal/Metal.h>
#include <stddef.h>
#include <stdint.h>

#define FF_VERTEX_RESOURCE_LIMIT 32
#define FF_VERTEX_BYTES_LIMIT (32u * 1024u * 1024u)
/* A 256-draw pass can have distinct per-draw constants. Metadata cardinality
 * is independent of the fixed byte budgets above/below. */
#define FF_DRAW_RESOURCE_LIMIT 1024
#define FF_CONSTANT_RESOURCE_LIMIT 14
#define FF_SHADER_FIELD_LIMIT 128
#define FF_SHADER_TABLE_BYTES_LIMIT 4096
#define FF_TEXTURE_RESOURCE_LIMIT 128
#define FF_TEXTURE_PLANE_LIMIT 128
#define FF_TEXTURE_BYTES_LIMIT (32u * 1024u * 1024u)
#define FF_SAMPLER_RESOURCE_LIMIT 32
static inline unsigned ff_texture_pixel_size(uint32_t format) {
    switch (format) {
    case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm:
    case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: return 1;
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Snorm: case MTLPixelFormatR16Float: return 2;
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatR32Float: case MTLPixelFormatRG16Float: return 4;
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG32Float: return 8;
    case MTLPixelFormatRGBA32Float: return 16;
    default: return 0;
    }
}
enum { FF_FIELD_BUFFER = 1, FF_FIELD_TEXTURE = 2, FF_FIELD_SAMPLER = 3, FF_FIELD_VALUE = 4 };
typedef struct { uint32_t offset, kind; } ff_shader_field;
typedef struct {
    uint32_t byte_length, field_count;
    ff_shader_field fields[FF_SHADER_FIELD_LIMIT];
} ff_shader_table_layout;
typedef struct {
    uint32_t ia_slot_mask, constant_count[2]; /* vertex, fragment */
    ff_shader_table_layout arguments[2];
} ff_draw_layout;

typedef struct {
    uint64_t id, generation;
    const void *bytes; /* receiver-owned snapshot, never a producer pointer */
    size_t length;
} ff_vertex_snapshot;
typedef struct {
    uint64_t id, generation, offset;
    uint32_t stride, length;
} ff_vertex_binding;
typedef struct {
    uint32_t offset, kind;
    uint64_t value; /* integer bits, or texture/sampler snapshot ID */
    ff_vertex_binding buffer;
} ff_argument_binding;
typedef struct { uint32_t mip, slice; size_t offset, row_bytes, length; } ff_texture_plane;
/* Cube descriptors retain Metal array_length=1. Their planes enumerate all
 * six physical face slices, with mip varying fastest, exactly like blit APIs. */
typedef struct {
    uint64_t id;
    uint32_t format, texture_type, width, height, mip_count, array_length, plane_count;
    uint32_t has_swizzle, swizzle[4]; /* Metal channel enums0..5; absent means RGBA */
    const void *bytes;
    size_t length;
    ff_texture_plane planes[FF_TEXTURE_PLANE_LIMIT];
} ff_texture_snapshot;
typedef struct {
    uint64_t id;
    uint32_t address[3], min_filter, mag_filter, mip_filter, compare, border, max_anisotropy;
    float lod_min, lod_max;
    uint32_t normalized, lod_average;
} ff_sampler_snapshot;
typedef struct {
    const ff_vertex_binding *vertices;
    size_t vertex_count;
    const ff_vertex_binding *constants[2];
    size_t constant_count[2];
    const ff_argument_binding *arguments[2];
    size_t argument_count[2], argument_bytes[2];
    const ff_vertex_binding *index;
    const ff_texture_snapshot *textures;
    size_t texture_count;
    const ff_sampler_snapshot *samplers;
    size_t sampler_count;
} ff_draw_bindings;

typedef struct ff_vertex_resources ff_vertex_resources;
/* Bindings are in the packed order selected by the shader's vertex-slot mask.
 * Returns NULL on unknown IDs/generations, ambiguous IDs, invalid ranges,
 * resource exhaustion or failure to allocate. No partially built result escapes. */
ff_vertex_resources *ff_vertex_resources_create(id<MTLDevice> device,
    const ff_vertex_snapshot *snapshots, size_t snapshot_count,
    const ff_vertex_binding *bindings, size_t binding_count);
ff_vertex_resources *ff_vertex_resources_create_draw(id<MTLDevice> device,
    const ff_vertex_snapshot *snapshots, size_t snapshot_count, const ff_draw_bindings *bindings);
/* Allocate immutable assets once for an ordered pass. Per-draw tables retain
 * these same Metal objects; they never upload the full graph again. The graph
 * may be destroyed after all draw tables have been constructed. Each draw must
 * still live until its GPU work completes. Binding a graph itself is a no-op. */
ff_vertex_resources *ff_vertex_resources_create_graph(id<MTLDevice> device,
    const ff_vertex_snapshot *snapshots, size_t snapshot_count,
    const ff_texture_snapshot *textures, size_t texture_count,
    const ff_sampler_snapshot *samplers, size_t sampler_count);
ff_vertex_resources *ff_vertex_resources_create_draw_shared(ff_vertex_resources *graph,
    const ff_draw_bindings *bindings);
id<MTLBuffer> ff_vertex_resources_index(ff_vertex_resources *resources, NSUInteger *offset);
/* Call during the target ordinary render encoder, before drawing. */
void ff_vertex_resources_bind(ff_vertex_resources *resources, id<MTLRenderCommandEncoder> encoder);
/* Caller must hold the result until every native GPU use has completed. */
void ff_vertex_resources_destroy(ff_vertex_resources *resources);
#endif
