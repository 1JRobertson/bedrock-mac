/* Experimental pointer-free, little-endian typed pass metadata.
 * No production producer or consumer routes this protocol yet. */
#ifndef FULLFRAME_METADATA_WIRE_V1_H
#define FULLFRAME_METADATA_WIRE_V1_H
#include <stdint.h>

#define FFMD_MAGIC UINT64_C(0x314154454d444646) /* "FFDMETA1" in LE bytes */
#define FFMD_VERSION 1u
#define FFMD_MAX_BYTES (2u*1024u*1024u)
#define FFMD_MAX_SECTIONS 24u
#define FFMD_NO_BINDING UINT32_MAX
#define FFMD_COMPLETE_PASS 1u

enum ffmd_kind { FFMD_PLAN=1, FFMD_GRAPH=2, FFMD_SIDECAR=3 };
enum ffmd_attachment_role {
    FFMD_ATTACHMENT_COLOR=1, FFMD_ATTACHMENT_COLOR_RESOLVE=2,
    FFMD_ATTACHMENT_DEPTH=3, FFMD_ATTACHMENT_STENCIL=4
};
enum ffmd_shared_role { FFMD_SHARED_ABSENT=0, FFMD_SHARED_COLOR=1,
    FFMD_SHARED_DEPTH=2, FFMD_SHARED_STENCIL=3 };
enum ffmd_section_type {
    FFMD_PLAN_DRAW=1, FFMD_PLAN_ARGUMENT_SLOT=2,
    FFMD_GRAPH_SNAPSHOT=16, FFMD_GRAPH_DRAW=17, FFMD_GRAPH_BINDING=18,
    FFMD_GRAPH_ARGUMENT_VALUE=19, FFMD_GRAPH_TEXTURE=20,
    FFMD_GRAPH_TEXTURE_PLANE=21, FFMD_GRAPH_SAMPLER=22,
    FFMD_SIDECAR_RESOURCE=32, FFMD_SIDECAR_SNAPSHOT_INDEX=33,
    FFMD_SIDECAR_TEXTURE_INDEX=34, FFMD_SIDECAR_ATTACHMENT=35,
    FFMD_SIDECAR_COMMAND_TYPE=36
};

#pragma pack(push,1)
typedef struct {
    uint64_t magic;
    uint16_t version,kind;
    uint32_t total_bytes,section_count,flags,reserved;
    uint64_t stream,frame,chunk,payload_id,cut_id;
    /* PLAN zeros all five identity fields and this digest. GRAPH and SIDECAR
     * carry the same current identity and exact plan-byte SHA-256. */
    uint8_t plan_sha256[32];
} ffmd_header;
typedef struct {
    uint16_t type,version;
    uint32_t stride,count,offset,bytes; /* bytes == stride * count; no overlap */
} ffmd_section;
/* The section table immediately follows the 100-byte header. Each kind uses
 * its exact ascending section IDs (2 plan, 7 graph, 5 sidecar); no unknown or
 * duplicate section is accepted. Data sections are contiguous after the table,
 * in that order, with offset starting at 100 + 20*section_count. Every row is
 * copied with memcpy before reading; byte products and total are checked before
 * allocation. All reserved fields/flags except FFMD_COMPLETE_PASS are zero. */

/* Immutable structural plan, keyed by SHA-256 of the complete plan blob. */
typedef struct {
    uint32_t ia_slot_mask,primitive;
    uint16_t vertex_count,constant_count[2],argument_count[2]; /* binding counts */
    uint8_t indexed,index_type;
    uint16_t reserved;
    uint32_t argument_slot_first[2];
} ffmd_plan_draw;
typedef struct { uint32_t offset,kind; } ffmd_plan_argument_slot;
/* Current pass values. File names are implied by 1-based row positions. */
typedef struct {
    uint32_t generation,has_provenance;
    uint64_t length,source_incarnation,source_generation,source_offset;
} ffmd_graph_snapshot;
typedef struct {
    uint32_t start,count,instances,base_instance;
    int32_t base_vertex;
    /* Ordinary binding range: vertices, vertex constants, fragment constants,
     * then optional indexed binding. Argument buffer bindings live in the
     * trailing part of FFMD_GRAPH_BINDING and are referenced by argument rows. */
    uint32_t binding_first,argument_first,index_binding;
    uint64_t index_count,index_offset;
} ffmd_graph_draw;
typedef struct { uint64_t id,generation,offset; uint32_t stride,length; } ffmd_graph_binding;
/* Buffer arguments point to consecutive trailing binding rows in draw/stage
 * traversal order. Every other argument uses FFMD_NO_BINDING. */
typedef struct { uint64_t value; uint32_t buffer_binding,reserved; } ffmd_graph_argument_value;
typedef struct {
    uint32_t format,texture_type,width,height,mip_count,array_length;
    uint32_t has_swizzle,swizzle[4],plane_first,plane_count;
    uint64_t length;
} ffmd_graph_texture;
typedef struct { uint32_t mip,slice; uint64_t offset,row_bytes,length; } ffmd_graph_texture_plane;
typedef struct {
    uint32_t address[3],min_filter,mag_filter,mip_filter,compare,border,max_anisotropy;
    uint32_t normalized,lod_average;
    uint32_t lod_min_bits,lod_max_bits; /* IEEE-754 binary32, validated after memcpy */
} ffmd_graph_sampler;

/* One resource row per original producer resource. Snapshot and texture rows
 * reference it by index instead of repeating its full descriptor. */
typedef struct {
    uint64_t kind,root,view,allocation_generation,input_content_version,output_content_version;
    uint64_t offset,length,buffer_base_offset,buffer_length;
    uint32_t flags,role,base_mip,base_slice,mip_count,slice_count;
    uint32_t format,type,width,height,array_length,sample_count,swizzle[4];
} ffmd_sidecar_resource;
typedef struct { uint16_t resource_index,reserved; } ffmd_sidecar_index;
typedef struct {
    uint16_t resource_index;
    uint8_t role,index;
    uint32_t level,slice,depth_plane;
    uint64_t shared_cut_id; /* zero iff shared_role == FFMD_SHARED_ABSENT */
    uint8_t shared_role,shared_index;
    uint16_t reserved;
} ffmd_sidecar_attachment;
typedef struct { uint32_t command_type; } ffmd_sidecar_command;
#pragma pack(pop)

_Static_assert(sizeof(ffmd_header)==100,"header layout");
_Static_assert(sizeof(ffmd_section)==20,"section layout");
_Static_assert(sizeof(ffmd_graph_binding)==32,"binding layout");
#endif
