#ifndef BEDROCK_FRAME_STREAM_PRIVATE_H
#define BEDROCK_FRAME_STREAM_PRIVATE_H
/* Paired in-process PE/Unix preparation ABI. Unlike frame_stream.h these
 * objects contain local handles/pointers and MUST NEVER be written to disk. */
typedef struct ffs_producer_context ffs_producer_context;
#include "winemetal.h"
#define FFS_PREPARE_MAGIC UINT64_C(0x4244465052455031)
#define FFS_PREPARE_VERSION 1u
#define FFS_PREPARE_CHUNK 256u
enum ffs_resource_role {
  FFS_ROLE_SHADER = 0, FFS_ROLE_COLOR = 1, FFS_ROLE_COLOR_RESOLVE = 9,
  FFS_ROLE_DEPTH = 17, FFS_ROLE_STENCIL = 18, FFS_ROLE_PRESENT = 19
};
typedef struct ffs_producer_resource {
  uint64_t handle,kind,root,view,allocation_generation;
  uint64_t input_content_version,output_content_version,offset,length;
  uint32_t flags,role;
  uint64_t buffer_base_offset,buffer_length;
} ffs_producer_resource;
typedef struct ffs_producer_dependency {
  uint64_t domain,id,value,stage,action,payload_id;
  uint32_t flags,reserved;
} ffs_producer_dependency;
typedef struct ffs_present_info {
  uint64_t source_format,effective_colorspace,gamma_version,sample_count;
  double drawable_width,drawable_height;
  float edr_scale,max_content_luminance,max_display_luminance;
  uint32_t hdr_metadata_enabled;
} ffs_present_info;
struct ffs_producer_context {
  uint64_t magic;
  uint32_t version,bytes;
  uint64_t stream,frame,chunk,completion;
  uint32_t encoder,category;
  uint64_t command_count,resource_count;
  struct WMTConstMemoryPointer resources;
  struct WMTConstMemoryPointer present;
  struct WMTConstMemoryPointer commands,dependencies;
  uint64_t dependency_count,readback_index,query_count;
};
#ifdef __cplusplus
static_assert(sizeof(ffs_producer_context)==128 && sizeof(ffs_producer_resource)==96 && sizeof(ffs_present_info)==64,"paired frame preparation ABI");
#else
_Static_assert(sizeof(ffs_producer_context)==128 && sizeof(ffs_producer_resource)==96 && sizeof(ffs_present_info)==64,"paired frame preparation ABI");
#endif
#endif
