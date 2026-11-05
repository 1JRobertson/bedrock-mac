/* Bounded local x86/ARM chunk transport. No pointers or Metal handles on wire. */
#ifndef BEDROCK_CHUNK_STREAM_H
#define BEDROCK_CHUNK_STREAM_H
#include <stddef.h>
#include <stdint.h>
#include "frame_stream.h"
#ifdef __cplusplus
extern "C" {
#endif

#define FFSC_VERSION 1u
#define FFSC_PACKET_MAGIC UINT64_C(0x424443484e4b3031)
#define FFSC_MAX_PACKET_BYTES (64u * 1024u * 1024u)
#define FFSC_MAX_SLOTS 2u
#define FFSC_MAX_BLOBS 4096u
#define FFSC_MAX_RETIREMENTS 4096u
#define FFSC_RECEIPT_CAPACITY 256u
#define FFSC_PRESENT_HISTORY 16u
#define FFSC_BLOB_NAME_BYTES 96u
#define FFSC_CACHE_MAX_BYTES (128u * 1024u * 1024u)
#define FFSC_CACHE_MAX_BLOBS 4096u
#define FFSC_SHARED_SNAPSHOT_ALIGNMENT 16384u
/* Launcher creates a private mode0600 regular file in a mode0700 directory.
 * Both processes open the same absolute path from this environment variable.
 * Creator initializes with ffsc_create; producer/native attach distinct roles.
 * Worker consumes the existing one-time private frame.arm trigger and calls
 * ffsc_arm after world load. No per-frame arm/receipt files are created. */
#define FFSC_ENDPOINT_ENV "BEDROCK_FULLFRAME_CHUNK_STREAM"
#define FFSC_RECEIVER_DIGEST_ENV "BEDROCK_NATIVE_RECEIVER_DIGEST"

enum ffsc_role { FFSC_PRODUCER = 1, FFSC_NATIVE = 2 };
enum ffsc_result { FFSC_OK, FFSC_EMPTY, FFSC_BACKPRESSURE, FFSC_CLOSED,
    FFSC_PEER_DEAD, FFSC_INVALID, FFSC_ORDER, FFSC_TOO_LARGE, FFSC_SOURCE_CLOSED };
enum ffsc_packet_flags { FFSC_FRAME_BEGIN = 1u, FFSC_FRAME_END = 2u,
    /* Mandatory publication proof from the source bridge's actual snapshot
     * GPU completion callback, after all immutable blob bytes are ready. It
     * attests only this chunk's source imports, never native GPU completion. */
    FFSC_SOURCE_READY = 4u };
enum ffsc_blob_flags {
    FFSC_BLOB_INLINE = 1u,
    /* Exact SHA256+length already retained by receiver. Sender may use this
     * only after TRANSPORT_CONSUMED of the original INLINE|CACHE publication.
     * Cache entries remain until explicit stream close; admission is bounded. */
    FFSC_BLOB_CACHED = 2u, FFSC_BLOB_CACHE = 4u,
    /* Opt-in snapshot buffers only. INLINE is required, CACHE/CACHED forbidden,
     * and wire sha256 must be zero. The receiver copies the immutable snapshot
     * then computes its exact SHA before content-based GPU asset reuse. */
    FFSC_BLOB_RECEIVER_DIGEST = 8u,
    /* Exclusive flag: a completed immutable cut-buffer snapshot in the private
     * arena named by the validated chunk manifest. offset is slot-relative,
     * page aligned; length is logical bytes. Zero SHA is resolved by native
     * hashing. The arena lease lasts through native GPU completion, independent
     * of chunk transport consumption. Never cached or mixed with INLINE. */
    FFSC_BLOB_SHARED_SNAPSHOT = 16u
};
typedef struct ffsc_packet_header {
    uint64_t magic;
    uint32_t version, bytes;
    uint64_t total_bytes, serial, stream, frame, chunk;
    uint64_t first_sequence, next_sequence, record_digest, queue_completion;
    uint32_t flags, record_count, blob_count, retirement_count;
    uint64_t records_offset, blobs_offset, retirements_offset;
} ffsc_packet_header;
/* Namespace=(payload_id,basename). Names are bounded ASCII basenames, no slash,
 * dot components, NUL inside name_bytes, or local handles. SHA256 covers exact
 * file bytes. Cached entries have offset0; inline bytes live wholly in packet.
 * Existing replay/bindings/graph/library/blob basenames retain their meanings.
 * Root worker resolves this to immutable in-memory payload factories. */
typedef struct ffsc_blob_entry {
    uint64_t payload_id, offset, length;
    uint32_t flags, name_bytes;
    unsigned char sha256[32];
    char name[FFSC_BLOB_NAME_BYTES];
} ffsc_blob_entry;
/* Source allocation release, never an inferred LRU eviction. Native releases
 * (kind,root,generation) only after last_use_serial GPU completion; no subsequent
 * packet may reference that generation. Completion of a frame is insufficient. */
typedef struct ffsc_retirement {
    uint64_t root, generation, last_use_serial;
    uint32_t kind, reserved;
} ffsc_retirement;
enum ffsc_receipt_kind {
    FFSC_NATIVE_GPU_COMPLETED = 1, FFSC_QUERY_READY, FFSC_PRESENTED, FFSC_ERROR,
    FFSC_OFFSCREEN_COMPLETED
};
enum ffsc_query_kind { FFSC_TIMESTAMP = 1, FFSC_OCCLUSION, FFSC_EVENT_QUERY, FFSC_MAP_READBACK };
enum ffsc_receipt_status { FFSC_COMPLETED = 0, FFSC_FAILED, FFSC_CANCELLED, FFSC_SUPERSEDED };
/* Separate bounded native->producer journal. Identity repeats the exact packet;
 * GPU/query receipts require matching queue_completion. PRESENTED is a
 * drawable command-buffer completion, not a display timestamp. OFFSCREEN is
 * the opt-in private-target command-buffer completion; both carry the exact
 * complete frame ledger digest. Query value is actual result, not elapsed time.
 * Timestamp identity=(chunk,index,count), value=native CB GPUEndTime nanoseconds.
 * Map readiness uses resource root/generation+offset/length after readback bytes
 * have actually returned to the source backing. A ready receipt alone never
 * substitutes for copying those bytes or issuing the original query object. */
typedef struct ffsc_receipt {
    uint32_t version, kind, status, query_kind;
    uint64_t serial, stream, frame, chunk, record_digest, queue_completion;
    uint64_t id, index, count, value, root, generation, offset, length;
} ffsc_receipt;

typedef struct ffsc_endpoint ffsc_endpoint;
/* Canonical buffer/page names eligible for receiver-computed content identity. */
int ffsc_receiver_digest_name(const char *name);
int ffsc_shared_snapshot_name(const char *name);
/* slots in[1,2], packetBytes in[4096,64MiB], page aligned. Creation sizes and
 * initializes an empty private file; attach validates ownership, mode, nlink,
 * exact size and ABI. Each role may be claimed once. PIDs are pinned at attach;
 * every operation checks close and peer death. Never recycles a live peer role. */
enum ffsc_result ffsc_create(int fd, uint32_t slots, uint32_t packetBytes);
enum ffsc_result ffsc_attach(int fd, enum ffsc_role role, ffsc_endpoint **out);
void ffsc_destroy(ffsc_endpoint *endpoint);
enum ffsc_result ffsc_arm(ffsc_endpoint *native);
int ffsc_is_armed(ffsc_endpoint *producer);
/* Nonblocking. A successful reserve owns one mutable slot until publish/abort.
 * Publish validates envelope/table/range/order before release publication.
 * Serials start1 and remain contiguous across frames. No >64MiB fragmentation. */
enum ffsc_result ffsc_reserve(ffsc_endpoint *producer, void **bytes, size_t *capacity);
enum ffsc_result ffsc_publish(ffsc_endpoint *producer, size_t bytes);
void ffsc_abort(ffsc_endpoint *producer);
/* Peek keeps transport ownership until consume. Consumer must copy/retain all
 * inputs into immutable native-owned storage BEFORE consume. This immediately
 * releases command slot credit, independent of GPU/query/presenter progress. */
enum ffsc_result ffsc_peek(ffsc_endpoint *native, const void **bytes, size_t *length);
enum ffsc_result ffsc_consume(ffsc_endpoint *native, uint64_t serial);
uint64_t ffsc_transport_consumed(ffsc_endpoint *producer);
enum ffsc_result ffsc_send_receipt(ffsc_endpoint *native, const ffsc_receipt *receipt);
enum ffsc_result ffsc_receive_receipt(ffsc_endpoint *producer, ffsc_receipt *receipt);
/* Validate untrusted immutable packet layout before traversing any pointer.
 * SHA256 verification and cache/resource ownership belong to root provider. */
enum ffsc_result ffsc_validate_packet(const void *bytes, size_t length);
/* Stop is sticky and wakes the polling wait. No completion is fabricated.
 * wait returns on data/credit/receipt/close/peer death or timeout (EMPTY).
 * Max wait1000ms keeps caller cancellation responsive; no application quits. */
void ffsc_stop(ffsc_endpoint *endpoint);
/* Source process atexit only: distinguish orderly exit from failure or peer
 * death. Cancels unconsumed publications without claiming GPU completion.
 * A prior/later failure stop wins; the native role cannot mark source exit. */
void ffsc_source_close(ffsc_endpoint *producer);
enum ffsc_result ffsc_wait(ffsc_endpoint *endpoint, uint32_t timeout_ms);

#ifdef __cplusplus
}
static_assert(sizeof(ffsc_packet_header)==128 && sizeof(ffsc_blob_entry)==160 &&
    sizeof(ffsc_retirement)==32 && sizeof(ffsc_receipt)==128,"chunk stream wire ABI");
#else
_Static_assert(sizeof(ffsc_packet_header)==128 && sizeof(ffsc_blob_entry)==160 &&
    sizeof(ffsc_retirement)==32 && sizeof(ffsc_receipt)==128,"chunk stream wire ABI");
#endif
#endif
