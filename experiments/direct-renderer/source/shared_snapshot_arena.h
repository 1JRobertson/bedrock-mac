/* Private four-slot cross-process snapshot arena. No addresses are serialized. */
#ifndef BEDROCK_SHARED_SNAPSHOT_ARENA_H
#define BEDROCK_SHARED_SNAPSHOT_ARENA_H
#include <stddef.h>
#include <stdint.h>

#define FFSA_ALIGNMENT 16384u
#define FFSA_SLOT_COUNT 4u
#define FFSA_MAX_SLOT_BYTES (32u * 1024u * 1024u)

typedef struct ffsa_endpoint ffsa_endpoint;
typedef enum { FFSA_SOURCE=1, FFSA_NATIVE=2 } ffsa_role;
typedef enum {
    FFSA_OK=0, FFSA_BACKPRESSURE=1, FFSA_STOPPED=2,
    FFSA_PEER_DEAD=3, FFSA_INVALID=4, FFSA_ORDER=5
} ffsa_result;

typedef struct {
    uint32_t slot;
    uint32_t reserved;
    uint64_t generation;
    uint64_t serial;
} ffsa_lease;

/* offset is slot-relative; length is logical bytes; allocated_length is the
 * 16 KiB rounded Metal/mmap extent. All fields must be checked by the native
 * side against a sealed lease before any pointer is exposed. */
typedef struct {
    ffsa_lease lease;
    uint64_t offset;
    uint64_t length;
    uint64_t allocated_length;
} ffsa_extent_desc;

/* Caller opens a newly created O_EXCL|O_NOFOLLOW regular 0600 file owned by
 * this UID. create requires an empty file and sets its exact final length.
 * Both processes retain their own FD until attach completes, then may close it.
 * slot_bytes is 16 KiB aligned, 16 KiB..32 MiB; the control page is 16 KiB. */
ffsa_result ffsa_create(int fd,uint64_t slot_bytes);
ffsa_result ffsa_attach(int fd,ffsa_role role,ffsa_endpoint **out);

/* SOURCE: claim only a free slot for one nonzero FFSC chunk serial. If all
 * slots are busy, return BACKPRESSURE so the caller can use copying instead.
 * Source allocation is locally mutex serialized for concurrent callbacks. */
ffsa_result ffsa_claim(ffsa_endpoint *source,uint64_t serial,ffsa_lease *out);
ffsa_result ffsa_allocate(ffsa_endpoint *source,ffsa_lease lease,uint64_t length,
    ffsa_extent_desc *out,void **bytes);
/* SOURCE only: abandon a CLAIMED lease when the caller guarantees no pending
 * source GPU work, Metal wrapper, exported descriptor, or future write can
 * reference any extent. Permits first-allocation or first-wrapper fallback.
 * SEALED/native-owned leases reject; the next claim increments generation. */
ffsa_result ffsa_source_abandon(ffsa_endpoint *source,ffsa_lease lease);
/* Call only after every source GPU write to the lease completed successfully.
 * Sealing makes used extents immutable and visible to the native process.
 * Source Metal wrappers must not unmap individual arena extents; retain the
 * endpoint/mapping until all source GPU users have completed, including stop. */
ffsa_result ffsa_seal(ffsa_endpoint *source,ffsa_lease lease);

/* NATIVE: acquire a sealed exact slot/generation/serial once. pin validates
 * an extent against sealed used bytes and retains a local view reference.
 * Pair each pin with unpin from the final immutable view/MTL deallocator. */
ffsa_result ffsa_acquire(ffsa_endpoint *native,ffsa_lease lease,uint64_t *used);
ffsa_result ffsa_pin_extent(ffsa_endpoint *native,ffsa_extent_desc descriptor,void **bytes);
ffsa_result ffsa_unpin_extent(ffsa_endpoint *native,ffsa_lease lease);
/* Mark immediately before first native GPU submission. A decode failure before
 * submission may abandon after all pins drop. Once submitted, only an actual
 * GPU completion permits release. The endpoint must outlive every pin and
 * Metal wrapper deallocator, including on cancellation/terminal stop.
 * After terminal stop, exact already-acquired leases may still abandon before
 * submission or mark real GPU completion and release; new claims/acquires/pins
 * remain blocked and the stopped arena cannot reuse freed slots. */
ffsa_result ffsa_native_submitted(ffsa_endpoint *native,ffsa_lease lease);
ffsa_result ffsa_native_abandon(ffsa_endpoint *native,ffsa_lease lease);
/* Call only after all native GPU commands using this lease completed. release
 * refuses reuse until GPU completion was declared and every pin was removed. */
ffsa_result ffsa_native_gpu_complete(ffsa_endpoint *native,ffsa_lease lease);
ffsa_result ffsa_release(ffsa_endpoint *native,ffsa_lease lease);

/* Terminal stop/peer death prohibits subsequent claim/reuse. No process-wide
 * cleanup or game/application shutdown occurs. detach refuses live native pins;
 * callers must also drain source GPU users before detaching a stopped source. */
void ffsa_stop(ffsa_endpoint *endpoint);
ffsa_result ffsa_detach(ffsa_endpoint *endpoint);
const char *ffsa_result_name(ffsa_result result);

#endif
