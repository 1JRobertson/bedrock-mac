/* Native renderer ownership of an exact completed attachment bundle. */
#ifndef FULLFRAME_SHARED_TEXTURE_EXECUTOR_H
#define FULLFRAME_SHARED_TEXTURE_EXECUTOR_H
#import "shared_texture.h"
typedef void *FFSTExecutorAttachments;
/* One authenticated consumer connection for an execution/cache lifetime.
 * Independent cut handles may coexist up to the protocol limit. Closing the
 * session rejects new acquires and defers connection teardown until every
 * handle has retired/been abandoned and released. No reconnect or role reuse. */
@interface FFSTExecutorSession : NSObject
- (FFSTExecutorAttachments)acquire:(uint64_t)cut device:(id<MTLDevice>)device
    timeout:(double)timeout failure:(NSString **)failure;
- (void)close;
@end
/* The renderer owns a handle on one serial execution thread. Do not overlap
 * finish/wait/release calls or start a call after release. IPC callbacks are
 * synchronized internally and do not invoke renderer code. */
/* Reads the parent-owned SERVICE/TOKEN/DEVICE environment. Polls the broker for
 * one exact cut, at most timeout_seconds (1..30). This legacy helper owns a
 * one-cut session; continuous callers retain FFSTExecutorSession instead.
 * Returns NULL on mismatch or
 * unavailable transport. Call off the UI/event thread for continuing playback. */
FFSTExecutorAttachments ffst_executor_acquire(id<MTLDevice> device, uint64_t cut_id, double timeout_seconds);
/* Borrowed until release. Shared depth/stencil refs return the same object. */
id<MTLTexture> ffst_executor_texture(FFSTExecutorAttachments attachments, FFSTAttachmentRole role, uint32_t index);
/* Exact producer provenance retained independently from lease retirement. */
int ffst_executor_texture_info(FFSTExecutorAttachments attachments, FFSTAttachmentRole role, uint32_t index, FFSTTextureInfo *info);
size_t ffst_executor_attachment_count(FFSTExecutorAttachments attachments);
/* Install before commit, after encoding every use of imported attachments.
 * Do not access imported storage in any later GPU command. Present an owned
 * resolved/copy texture instead. finish preserves the bundle through GPU+ACK. */
int ffst_executor_finish(FFSTExecutorAttachments attachments, id<MTLCommandBuffer> command);
FFSTResult ffst_executor_wait(FFSTExecutorAttachments attachments, double timeout_seconds);
/* On an unsubmitted bundle, asynchronously abandons and waits for retirement
 * acknowledgement before destroying the connection. Otherwise completion owns
 * cleanup. Safe to call with NULL. No installed service/global cleanup. */
void ffst_executor_release(FFSTExecutorAttachments attachments);
#endif
