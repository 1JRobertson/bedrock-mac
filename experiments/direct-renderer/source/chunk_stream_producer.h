#ifndef BEDROCK_CHUNK_STREAM_PRODUCER_H
#define BEDROCK_CHUNK_STREAM_PRODUCER_H
#include "chunk_stream.h"
#include "frame_stream_private.h"
#include "chunk_completion.h"
#include "readback_stream.h"
#include "shared_snapshot_arena.h"
#include "vertex_resources.h"
#import <Metal/Metal.h>
#ifndef FFSC_PRODUCER_API
#define FFSC_PRODUCER_API
#endif
FFSC_PRODUCER_API int fullframe_chunk_stream_enabled(void);
/* One additional chunk may overlap the usual three-chunk frame. Payload and
 * shared-load limits remain authoritative independently of two wire slots. */
#define FFSC_SOURCE_STAGING_CHUNKS 4u
#define FFSC_SOURCE_STAGING_CHUNKS_EXPERIMENT 8u
#define FFSC_SOURCE_PIPELINE_DEPTH_ENV "BEDROCK_FULLFRAME_PIPELINE_DEPTH"
#define FFSC_SOURCE_CAPTURE_HEADROOM (UINT64_C(256)*1024*1024)
#define FFSC_SOURCE_CAPTURE_HEADROOM_EXPERIMENT (UINT64_C(128)*1024*1024)
#define FFSC_SOURCE_HEADROOM_ENV "BEDROCK_FULLFRAME_ADMISSION_HEADROOM_MIB"
FFSC_PRODUCER_API uint32_t fullframe_chunk_stream_record(const ffs_record *,uint64_t);
FFSC_PRODUCER_API int fullframe_chunk_payload_open(const ffs_producer_context *,uint64_t payload);
FFSC_PRODUCER_API int fullframe_chunk_blob_write(int,const char *,const void *,size_t);
/* Fresh, GPU-completed cut and operation snapshots may use the shared arena.
 * Otherwise the ordinary copied path remains available. */
FFSC_PRODUCER_API int fullframe_chunk_blob_write_completed_snapshot(int,const char *,id<MTLBuffer>,size_t);
FFSC_PRODUCER_API int fullframe_chunk_blob_write_shared_snapshot(int,const char *,id<MTLBuffer>,size_t,
    ffsa_extent_desc);
/* Returns a +1 MTLBuffer or nil for the ordinary copied staging allocation. */
FFSC_PRODUCER_API id<MTLBuffer> fullframe_chunk_snapshot_allocate(int,id<MTLDevice>,size_t,ffsa_extent_desc *);
FFSC_PRODUCER_API int fullframe_chunk_payload_retained_limit(int,uint64_t);
/* Producer-local memo lookup hint only. It never attests content or bypasses
 * comparison of fresh snapshot bytes. Allocation generations may rename. */
FFSC_PRODUCER_API int fullframe_chunk_blob_identity(int,const char *,uint64_t kind,uint64_t root,uint64_t view,uint64_t offset,uint64_t length);
/* Optional retained immutable private-texture owner, exposing bytes/length.
 * First capture and every unqualified/missing/evicted proof use fresh bytes.
 * The owner pins the existing memo budget until released by the source cut. */
FFSC_PRODUCER_API id fullframe_chunk_private_texture(int,const char *,const ffs_producer_resource *,const ff_texture_snapshot *);
/* Retain an exact proven owner through transport, permitting its already-charged
 * memo backing to replace the duplicate texture staging reservation. */
FFSC_PRODUCER_API int fullframe_chunk_retain_texture_budget(int,const char *,id);
FFSC_PRODUCER_API void fullframe_chunk_release_texture_budget(int);
/* Ordered replay coverage only, never GPU/CPU completion evidence. A true result
 * means an earlier captured native write defines this entire buffer range
 * in the exact allocation generation and input version. Native FIFO execution
 * and defined-range validation remain mandatory; unknown ranges return false. */
FFSC_PRODUCER_API int fullframe_chunk_buffer_has_prior_native_write(const ffs_producer_context *,const ffs_producer_resource *);
FFSC_PRODUCER_API uint64_t fullframe_chunk_payload_bytes(int);
FFSC_PRODUCER_API void fullframe_chunk_payload_ready(int,const char *kind);
FFSC_PRODUCER_API int fullframe_chunk_source_completion(id<MTLCommandBuffer>,const ffs_producer_context *);
/* generation0 is a private source allocation-destruction notice. Published
 * retirement entries always enumerate exact observed nonzero generations. */
FFSC_PRODUCER_API uint32_t fullframe_chunk_stream_retire(uint64_t kind,uint64_t root,uint64_t generation);
/* Paired native completion is opt-in with the same PE/source flag. Begin can
 * bypass only an explicit stream0 before any captured frame; unknown waits and
 * queries never bypass. Command pointers remain private to the Unix bridge. */
#define FFSC_COMPLETION_ENV "DXMT_NATIVE_COMPLETION"
enum ffsc_completion_status {
    FFSC_COMPLETION_FAILED=0,FFSC_COMPLETION_BYPASS=1,
    FFSC_COMPLETION_CAPTURED=2,FFSC_COMPLETION_READY=3,FFSC_COMPLETION_PENDING=4,
    FFSC_COMPLETION_SUSPENDED=5
};
FFSC_PRODUCER_API uint32_t fullframe_chunk_completion_begin(void *,uint64_t stream,uint64_t chunk,uint64_t queue_completion);
FFSC_PRODUCER_API uint32_t fullframe_chunk_completion_wait(void *,uint64_t stream,uint64_t chunk,uint64_t queue_completion,uint32_t timeout_ms);
FFSC_PRODUCER_API uint32_t fullframe_chunk_completion_query(void *,uint64_t stream,uint64_t chunk,uint64_t queue_completion,
    uint32_t kind,uint64_t id,uint64_t index,uint64_t count,uint64_t expected_value,uint64_t *value);
FFSC_PRODUCER_API uint32_t fullframe_chunk_completion_release(void *,uint64_t stream,uint64_t chunk,uint64_t queue_completion);
/* Trusted type3 capture binds one original destination and exact tight rows.
 * Default-off completion needs no reverse channel. Captured completion requires
 * matching returned native bytes before it can expose CPU/Map readiness. */
FFSC_PRODUCER_API int fullframe_chunk_readback_register(const ffs_producer_context *,uint64_t payload,
    uint32_t command,uint32_t resource,uint64_t offset,uint64_t row_bytes,uint64_t row_length,uint64_t row_count);
/* Bounded source profiling only; times are monotonic CPU wall nanoseconds.
 * JSON/clone/hash costs overlap serialization/prepare; packet includes manifest
 * work and final assembly. Concurrent phase totals are not additive latency.
 * These calls never alter capture coverage or freshness. */
enum ffsc_profile_stage {FFSC_PROFILE_PREPARE=1,FFSC_PROFILE_SNAPSHOT_BUFFER,
    FFSC_PROFILE_SNAPSHOT_TEXTURE,FFSC_PROFILE_SERIALIZE,FFSC_PROFILE_IO_WAIT,FFSC_PROFILE_JSON,
    FFSC_PROFILE_COMPACT,FFSC_PROFILE_BUFFER_SINK,FFSC_PROFILE_TEXTURE_SINK,FFSC_PROFILE_GRAPH,
    FFSC_PROFILE_REPLAY,FFSC_PROFILE_SIDECAR};
FFSC_PRODUCER_API void fullframe_chunk_profile_context(const ffs_producer_context *,uint32_t stage,uint64_t nanoseconds,uint64_t bytes,uint64_t count);
FFSC_PRODUCER_API void fullframe_chunk_profile_token(int token,uint32_t stage,uint64_t nanoseconds,uint64_t bytes,uint64_t count);
/* Called after immutable packet transport ownership transfers; source capture
 * staging/files may release now, independently of native GPU resources. */
void fullframe_frame_stream_release_storage(uint64_t bytes);
/* Optional immutable digest samples share the existing aggregate payload
 * budget. Call outside source_lock; refusal only disables memo admission. */
int fullframe_frame_stream_reserve_memo(uint64_t bytes);
void fullframe_frame_stream_release_memo(uint64_t bytes);
/* Called only after dropping the payload budget mutex. */
FFSC_PRODUCER_API void fullframe_chunk_source_budget_changed(void);
/* Terminal serializer failure, called only outside the frame budget mutex. */
FFSC_PRODUCER_API void fullframe_chunk_source_serialization_failed(void);
/* At most two serializer/page workers share these permits. */
FFSC_PRODUCER_API void fullframe_chunk_serializer_enter(void);
FFSC_PRODUCER_API void fullframe_chunk_serializer_leave(void);
/* One lifetime reservation for the separate four-slot arena, never released by
 * transport consumption. Disabled mode reserves zero. */
int fullframe_frame_stream_reserve_snapshot_arena(uint64_t bytes);
/* Chunk-boundary preflight only:1ready,0wait for older committed chunks,-1failed.
 * Caller holds no source lock; this never waits on its own uncommitted capture. */
int fullframe_frame_stream_admission_ready(uint64_t headroom);
enum {FFSC_ADMISSION_COUNT=1,FFSC_ADMISSION_BUDGET=2,FFSC_ADMISSION_CUTS=4};
/* -1failed;0ready;otherwise the budget/cut reasons for a boundary wait. */
int fullframe_frame_stream_admission_reasons(uint64_t headroom);
#endif
