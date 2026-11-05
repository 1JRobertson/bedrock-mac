#ifndef BEDROCK_FRAME_STREAM_H
#define BEDROCK_FRAME_STREAM_H

/* Pointer-free, fixed-width little-endian producer/native interface. This is a
 * coverage ledger, not a substitute for command payloads or GPU completion. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FFS_MAGIC UINT64_C(0x42444652414d4531)
#define FFS_VERSION 1u
#define FFS_MAX_RECORDS 65536u
#define FFS_MAX_RESOURCES 4096u
#define FFS_MAX_GENERATIONS 8192u
#ifndef FFS_MAX_VIEWS
#define FFS_MAX_VIEWS 8192u
#endif
/* Per-collector view mapping plus its pointer, size and count fields. Kernel
 * VM bookkeeping and physical residency are outside this virtual-byte bound. */
#define FFS_VIEW_BUDGET_BYTES (608u * 1024u)
#define FFS_MAX_DEPENDENCIES 1024u
#define FFS_MAX_COMMANDS 65536u

enum ffs_record_kind {
  FFS_FRAME_BEGIN = 1, FFS_CHUNK_BEGIN, FFS_ENCODER_BEGIN, FFS_COMMAND,
  FFS_RESOURCE, FFS_DEPENDENCY, FFS_PRESENT, FFS_ENCODER_END,
  FFS_CHUNK_END, FFS_FRAME_END, FFS_REJECT, FFS_RESOURCE_UNRESOLVED
};

/* Values deliberately match DXMT's post-optimization EncoderType. Null is an
 * optimizer tombstone and must still occupy its ordered encoder slot. */
enum ffs_encoder_category {
  FFS_NULL, FFS_RENDER, FFS_COMPUTE, FFS_BLIT, FFS_CLEAR, FFS_RESOLVE,
  FFS_PRESENT_ENCODER, FFS_SPATIAL_UPSCALE, FFS_SIGNAL_EVENT,
  FFS_TEMPORAL_UPSCALE, FFS_WAIT_EVENT, FFS_TIMESTAMP, FFS_CATEGORY_COUNT
};

enum ffs_flags {
  FFS_UNSUPPORTED = 1u, FFS_EXTERNAL = 2u, FFS_READ = 4u,
  FFS_WRITE = 8u, FFS_ATTACHMENT = 16u, FFS_PAYLOAD = 32u
};
enum ffs_resource_kind { FFS_BUFFER = 1, FFS_TEXTURE, FFS_QUERY };
enum ffs_dependency_domain { FFS_FENCE = 1, FFS_INITIALIZER, FFS_QUEUE, FFS_EVENT };
enum ffs_dependency_action { FFS_WAIT = 1, FFS_SIGNAL };
enum ffs_emit_status { FFS_EMIT_IDLE, FFS_EMIT_ACCEPT, FFS_EMIT_REJECT };
enum ffs_status { FFS_INCOMPLETE, FFS_UNSUPPORTED_FRAME, FFS_COMPLETE, FFS_INVALID };
enum ffs_error {
  FFS_OK, FFS_BAD_PACKET, FFS_ORDER, FFS_COUNT, FFS_LIMIT, FFS_IDENTITY,
  FFS_DEPENDENCY_ERROR, FFS_RESOURCE_VERSION, FFS_MISSING_PRESENT, FFS_PRODUCER_REJECT
};

typedef struct ffs_record {
  uint64_t magic;
  uint32_t version, bytes, kind, flags;
  uint64_t stream, sequence, frame, chunk;
  uint32_t encoder, item;
  uint64_t data[12];
} ffs_record;

/* data[] contract:
 * FRAME_BEGIN: first actual chunk ID.
 * CHUNK_BEGIN: frame-local chunk ordinal, expected encoder count,
 *              initializer event value, queue completion event value.
 * ENCODER_BEGIN: category, expected commands/resources/dependencies, payload ID.
 * COMMAND: command type, payload ID; item is its zero-based list ordinal.
 * RESOURCE: kind, root ID, view ID, allocation generation, input content version,
 *           offset, length, payload ID, output content version. Root/view IDs
 *           are stable producer-issued integers, never addresses/GPU handles.
 *           A write advances content once at ENCODER_END. All aliased views
 *           read the same input version; duplicate writes have the same output.
 * RESOURCE_UNRESOLVED: reason, declared kind (zero if unknown). This occupies a
 *           resource slot and unconditionally makes the frame unsupported.
 * DEPENDENCY: domain, stable dependency ID, value, Metal stage bits, WAIT/SIGNAL,
 *             external dependency payload ID (zero for internal dependencies).
 * PRESENT: backbuffer root/view/allocation generation/content version.
 * ENCODER_END: actual command/resource/dependency counts.
 * CHUNK_END: actual encoders, commands, dependencies (including chunk events).
 * FRAME_END: actual chunks, encoders, commands, preceding records, FNV64 digest.
 * REJECT: producer reason code. Rejection is sticky.
 * All unused data words must be zero. Sequence is contiguous across a stream;
 * chunk is the actual queue chunk ID, encoder is chunk-local final order.
 */

typedef struct ffs_summary {
  enum ffs_status status;
  enum ffs_error error;
  uint64_t stream, frame, first_sequence, next_sequence, digest;
  uint64_t records, chunks, encoders, commands, resources, dependencies, presents;
  uint64_t category_count[FFS_CATEGORY_COUNT];
} ffs_summary;

/* Diagnostic counts are retained across frame resets and are independent of
 * per-frame record counters. The limit identifies the exact rejection site. */
enum ffs_limit_cause { FFS_LIMIT_NONE, FFS_LIMIT_RECORDS, FFS_LIMIT_SEQUENCE,
  FFS_LIMIT_GENERATIONS, FFS_LIMIT_VIEWS, FFS_LIMIT_DEPENDENCIES };
typedef struct ffs_occupancy {
  size_t generations, views, dependencies, stored_records, record_capacity;
  enum ffs_limit_cause limit;
} ffs_occupancy;
typedef struct ffs_collector ffs_collector;

/* first_sequence is supplied by the trusted stream receiver (normally 1).
 * A collector accepts one complete frame. max_records bounds all allocations. */
ffs_collector *ffs_create(uint64_t stream, uint64_t first_sequence, size_t max_records);
void ffs_destroy(ffs_collector *collector);
int ffs_consume(ffs_collector *collector, const ffs_record *record);
ffs_summary ffs_inspect(const ffs_collector *collector);
ffs_occupancy ffs_inspect_occupancy(const ffs_collector *collector);
const char *ffs_limit_name(enum ffs_limit_cause cause);
/* Exact page-rounded mapped view storage, including index and free list. */
size_t ffs_view_storage_bytes(const ffs_collector *collector);
const ffs_record *ffs_records(const ffs_collector *collector, size_t *count);
uint64_t ffs_digest(uint64_t prior, const ffs_record *record);

/* This only grants permission to ATTEMPT native replay. It never attests GPU
 * completion or permits releasing original DXMT resources/query readbacks.
 * Every non-null encoder, command, resource and external wait needs a payload
 * and a successful backend evidence check. Metadata-only captures fail. */
typedef int (*ffs_native_evidence)(const ffs_record *, void *context);
int ffs_can_replay(const ffs_collector *, ffs_native_evidence, void *context);
/* Incremental permission at an accepted CHUNK_END (optional real FRAME_END).
 * first_sequence is the exact optional FRAME_BEGIN/CHUNK_BEGIN packet prefix.
 * Only this complete chunk's evidence is checked; no frame end is synthesized.
 * Invalid or unsupported earlier coverage remains sticky and rejects. */
int ffs_can_replay_chunk(const ffs_collector *, uint64_t first_sequence,
    ffs_native_evidence, void *context);
/* Release stored command packets at a validated chunk boundary while retaining
 * counts/digest/resource/dependency validation state. This is transport storage
 * reuse, never GPU/query completion. Whole-frame replay becomes ineligible;
 * incremental validation can continue beyond the bounded record capacity. */
int ffs_discard_consumed_chunks(ffs_collector *);
/* Reuse validation state at the next REAL frame boundary. Sequence, resource
 * versions and dependency timelines persist; per-frame counts/digest reset. */
int ffs_begin_next_frame(ffs_collector *, uint64_t first_sequence);
/* Explicit source allocation lifetime release, only at a chunk boundary. The
 * caller must prove no later record will reference this generation: retirement
 * discards all identity/range and version history and cannot detect reuse.
 * Does not infer GPU retirement; native caller applies its GPU serial gate. */
int ffs_retire_generation(ffs_collector *,uint64_t kind,uint64_t root,uint64_t generation);
const char *ffs_status_name(enum ffs_status);

#ifdef __cplusplus
}
static_assert(sizeof(ffs_record) == 160, "frame stream wire ABI");
#else
_Static_assert(sizeof(ffs_record) == 160, "frame stream wire ABI");
#endif
#endif
