/* Exact Metal attachment ownership over real NSXPC; compile implementation with ARC. */
#ifndef FULLFRAME_SHARED_TEXTURE_H
#define FULLFRAME_SHARED_TEXTURE_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stddef.h>

#define FFST_MAX_TEXTURES 16
#define FFST_MAX_ATTACHMENTS 18
#define FFST_DEFAULT_MAX_CUTS 16
#define FFST_MAX_OUTSTANDING_LEASES 16u
#define FFST_DEFAULT_MAX_BYTES (512ull * 1024 * 1024)

typedef enum {
    FFST_OK = 0, FFST_EMPTY = 1, FFST_REJECTED = 2, FFST_GPU_FAILED = 3,
    FFST_DISCONNECTED = 4, FFST_EXPIRED = 5, FFST_CLOSED = 6
} FFSTResult;
typedef enum { FFST_COLOR = 1, FFST_DEPTH = 2, FFST_STENCIL = 3 } FFSTAttachmentRole;
typedef struct {
    uint64_t source_id, source_generation, source_level, source_slice;
    uint64_t pixel_format, texture_type, width, height, sample_count;
    uint64_t usage, allocated_bytes;
} FFSTTextureInfo;
typedef struct {
    uint64_t role, attachment_index, texture_index;
} FFSTAttachmentRef;
typedef struct {
    id<MTLTexture> texture; /* Fresh immutable shared copy, never original game allocation. */
    uint64_t source_id, source_generation, source_level, source_slice;
} FFSTTextureInput;
typedef void (^FFSTCompletion)(uint64_t cut_id, FFSTResult result);

typedef void *FFSTProducer;
typedef void *FFSTConsumer;
typedef void *FFSTLease;

#ifdef __cplusplus
extern "C" {
#endif

/* Shared admission predicates used by the pre-render copy helper. Format
 * eligibility is separate from actual device support/allocation success. */
int ffst_pixel_format_supported(uint64_t format);
int ffst_attachment_format_supported(uint64_t format, FFSTAttachmentRole role);
int ffst_sample_count_supported(id<MTLDevice> device, uint64_t count);

/* No singleton or global runtime changes. Every instance owns one NSXPC connection.
 * Token must be per-session unpredictable; service name is a fresh launchd label.
 * expected_broker_pid==0 permits a same-UID broker with the matching token.
 * Callbacks run on private serial queues; never synchronously wait on those queues.
 * Both clients require the exact device registryID, not MTLCreateSystemDefaultDevice(). */
FFSTProducer ffst_producer_create(NSString *service, NSString *token, id<MTLDevice> device,
    uint32_t max_cuts, uint64_t max_bytes, pid_t expected_broker_pid);
void ffst_producer_destroy(FFSTProducer producer);

/* Nonblocking. Command MUST already have status Completed; call from its completion
 * handler. All copies must precede that completion in the dependency-correct game
 * stream. The helper does not infer source fences or reconstruct a Load image.
 * cut_id must increase monotonically for this producer session.
 * Inputs are deduplicated exact 2D/2D-MSAA textures, one full mip/slice per copy;
 * attachment refs preserve depth/stencil aliasing through one texture index.
 * Returns 0 on synchronous rejection (no callback). On 1, retains copies until
 * consumer GPU completion + producer retirement ACK, or terminal IPC failure.
 * There is no reuse pool: releasing local ownership on IPC failure is safe only
 * because imported textures/command buffers retain their own Metal references.
 * Callback FFST_OK means GPU completion, not rendering correctness. */
int ffst_producer_publish(FFSTProducer producer, id<MTLCommandBuffer> completed_command,
    uint64_t cut_id, const FFSTTextureInput *textures, size_t texture_count,
    const FFSTAttachmentRef *attachments, size_t attachment_count, FFSTCompletion completion);

FFSTConsumer ffst_consumer_create(NSString *service, NSString *token, id<MTLDevice> device,
    pid_t expected_broker_pid);
void ffst_consumer_destroy(FFSTConsumer consumer);
/* Nonblocking poll. One acquire request at a time; up to16 acquired leases may
 * coexist on the same authenticated consumer connection. Leases count against
 * that limit until their terminal retirement ACK (or disconnection), including
 * while their GPU work is pending. EMPTY means no completed producer cut.
 * On OK, caller owns lease until finish/abandon.
 * A cut is atomic: all texture handles and role mappings arrive together. */
void ffst_consumer_acquire(FFSTConsumer consumer,
    void (^completion)(FFSTLease lease, FFSTResult result));
uint64_t ffst_lease_cut_id(FFSTLease lease);
size_t ffst_lease_texture_count(FFSTLease lease);
size_t ffst_lease_attachment_count(FFSTLease lease);
id<MTLTexture> ffst_lease_texture(FFSTLease lease, size_t index);
int ffst_lease_texture_info(FFSTLease lease, size_t index, FFSTTextureInfo *info);
int ffst_lease_attachment(FFSTLease lease, size_t index, FFSTAttachmentRef *attachment);
/* Consumes the lease. Install before commit, then commit exactly this consumer-owned
 * command buffer; no later GPU access may use the lease. Retains textures through
 * that buffer's completion, then sends explicit completion to broker. Callback
 * follows the producer retirement handshake. Close the client only after ALL
 * outstanding leases have completed, or to terminate the entire session. */
int ffst_consumer_finish(FFSTLease lease, id<MTLCommandBuffer> command,
    FFSTCompletion completion);
/* Consumes a lease which has never been submitted to GPU. */
void ffst_consumer_abandon(FFSTLease lease, FFSTCompletion completion);

/* Isolated ARM broker entry point. Blocks in run loop; caller owns temporary
 * launchd registration. Same UID enforced; optional PIDs pin each role. A token
 * claims one producer and one consumer connection for the service lifetime.
 * Timeout terminates the session rather than recycling an in-flight allocation.
 * max_age_seconds is bounded [1,300], hard queue caps are 16 cuts/1GiB. */
int ffst_broker_run(NSString *service, NSString *token, uint64_t registry_id,
    uint32_t max_cuts, uint64_t max_bytes, double max_age_seconds,
    pid_t producer_pid, pid_t consumer_pid);
#ifdef __cplusplus
}
#endif
#endif
