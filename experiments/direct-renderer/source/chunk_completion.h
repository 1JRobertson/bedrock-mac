/* Source-owned native completion evidence. No transport/GPU operations. */
#ifndef BEDROCK_CHUNK_COMPLETION_H
#define BEDROCK_CHUNK_COMPLETION_H
#include "chunk_stream.h"
#ifdef __cplusplus
extern "C" {
#endif

#define FFCC_CAPACITY 256u
#define FFCC_MAX_QUERIES (FFSC_RECEIPT_CAPACITY - 1u)
enum ffcc_result {
    FFCC_OK, FFCC_READY, FFCC_PENDING, FFCC_NOT_FOUND,
    FFCC_BACKPRESSURE, FFCC_FAILED
};
/* These are trusted expectations from the validated ORIGINAL source payloads,
 * never inferred from native results. Timestamp: id=packet.chunk, value=0;
 * event: id=stable event ID, index=0,count=1,value=declared signal threshold.
 * Timestamp index names one coalesced group; count is a number of query
 * objects, not an index range. Repeated timestamp indices and non-increasing
 * thresholds for the same event ID are rejected. Other kinds unsupported. */
typedef struct ffcc_query {
    uint32_t kind, reserved;
    uint64_t id, index, count, value;
} ffcc_query;
typedef struct ffcc_registry ffcc_registry;

/* One allocation, fixed upper bound: 256 packet identities, <=255 queries per
 * packet. Caller serializes ALL operations; source bridge owns its lock/waits.
 * Destroy only after callers stop. There is no reset after a protocol failure. */
ffcc_registry *ffcc_create(void);
void ffcc_destroy(ffcc_registry *registry);
/* Register BEFORE publication can expose the packet. Copies header and query
 * expectations. Source has already validated the complete ledger/payloads.
 * Serials start1 and remain contiguous, along with original sequence/chunk/
 * frame boundaries and increasing queue_completion. Reserved fields must0.
 * Capacity refusal changes no state;
 * never evict an old identity. Failed publication is retried under this same
 * registration, or ends the stream via ffcc_fail. */
enum ffcc_result ffcc_track(ffcc_registry *registry,
    const ffsc_packet_header *packet, const ffcc_query *queries, size_t count);
/* Accept only GPU_COMPLETED/QUERY_READY, or a terminal ERROR. Every packet
 * identity field and unused receipt field is checked. Receipts may arrive in any order;
 * all exact expected queries AND GPU must arrive before any readiness is
 * visible (returns READY; otherwise PENDING). Duplicate/unknown/error/mismatch
 * is a sticky registry failure. PRESENTED is routed separately by the caller. */
enum ffcc_result ffcc_accept(ffcc_registry *registry, const ffsc_receipt *receipt);
/* Nonblocking lookups use (stream,queue_completion), never consumed transport
 * credit. Missing identities/tuples return NOT_FOUND, which MUST NOT bypass a
 * source wait. Pending/failed/unknown lookup zeroes value/count outputs.
 * Event queries match the exact declared threshold, not a different watermark.
 * Timestamp lookup expectations keep value0; the returned value is native ns. */
enum ffcc_result ffcc_state(const ffcc_registry *registry,
    uint64_t stream, uint64_t queue_completion);
enum ffcc_result ffcc_lookup(const ffcc_registry *registry,
    uint64_t stream, uint64_t queue_completion, const ffcc_query *query,
    uint64_t *value);
/* Copy only query receipts, in registration order, once the whole packet is
 * complete. No partial copy on insufficient capacity; count reports required
 * capacity only when READY/BACKPRESSURE. Empty-query chunks copy zero entries. */
enum ffcc_result ffcc_copy(const ffcc_registry *registry,
    uint64_t stream, uint64_t queue_completion, ffsc_receipt *receipts,
    size_t capacity, size_t *count);
/* Optional terminal batch/deadline check: incomplete means missing evidence
 * and sticky failure. Requires the same six identity fields as release and
 * returns READY on success. GPU receipt itself is NOT a batch-end marker. */
enum ffcc_result ffcc_verify(ffcc_registry *registry,
    const ffsc_packet_header *packet);
/* Release only after original source QueryReadbacks consumed native results.
 * Requires exact {serial,stream,frame,chunk,digest,queue_completion} and whole
 * packet completion. Released identities stay unknown; old receipts poison.
 * The global serial/order history survives release. */
enum ffcc_result ffcc_release(ffcc_registry *registry,
    const ffsc_packet_header *packet);
void ffcc_fail(ffcc_registry *registry);

#ifdef __cplusplus
}
#endif
#endif
