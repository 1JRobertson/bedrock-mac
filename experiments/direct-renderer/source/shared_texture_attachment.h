/* Exact immutable Load-attachment copies at the original renderer's GPU cut.
 * Compile implementation with ARC. This does not suppress any original work. */
#ifndef FULLFRAME_SHARED_TEXTURE_ATTACHMENT_H
#define FULLFRAME_SHARED_TEXTURE_ATTACHMENT_H
#import "shared_texture.h"

typedef void *FFSTAttachmentCapture;
typedef struct {
    id<MTLTexture> texture;
    uint64_t source_id, source_generation;
    NSUInteger level, slice;
    FFSTAttachmentRole role;
    uint32_t attachment_index; /* color 0..7; depth/stencil 0 */
} FFSTAttachmentSource;

/* On success takes exclusive ownership of producer; never destroy it separately.
 * max_cuts/bytes bound allocations before GPU work is inserted. Device must be
 * the exact original command-buffer device. Only fresh copies are published. */
FFSTAttachmentCapture ffst_attachment_capture_create(FFSTProducer producer,
    id<MTLDevice> device, uint32_t max_cuts, uint64_t max_bytes);
/* Nonblocking close. Rejects future captures; already scheduled cuts retain the
 * context, producer and copies until their completion/terminal IPC result.
 * Caller must ensure no concurrent API entry can begin after this call. */
void ffst_attachment_capture_destroy(FFSTAttachmentCapture capture);

/* Call before opening the ORIGINAL render encoder, with exactly the attachment
 * versions required by MTLLoadActionLoad at that cut. Clear/DontCare attachments
 * need no copy and must be handled by the renderer's ordinary pass description.
 * All initializer/cross-queue waits must already be encoded. Supply every
 * relevant pre-raster fence; copied game allocations must obey their original
 * read lifetimes. Caller-owned IDs/generations are required provenance, not
 * inferred from pointers. 2D and 2D-MSAA, one full selected mip/slice per source.
 *
 * Success inserts one blit + a ready fence and delivers completion exactly once,
 * after consumer GPU completion + retirement ACK or terminal failure. The caller
 * MUST wait on ready_fence before original fragment/vertex work can overwrite
 * these source attachments. Publication happens only after this command buffer
 * completes. A zero return inserts no GPU work and invokes no completion.
 * Deduplication preserves combined depth/stencil as one imported texture. */
int ffst_attachment_capture_schedule(FFSTAttachmentCapture capture,
    id<MTLCommandBuffer> command, uint64_t cut_id,
    const FFSTAttachmentSource *sources, size_t source_count,
    const id<MTLFence> *fences, size_t fence_count,
    id<MTLFence> __autoreleasing *ready_fence, FFSTCompletion completion);
uint32_t ffst_attachment_capture_pending(FFSTAttachmentCapture capture, uint64_t *bytes);
#endif
