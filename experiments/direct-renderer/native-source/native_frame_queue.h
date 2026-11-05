/* Bounded CPU scheduling of validated immutable native frame requests.
 * Compile queue and executor blocks with ARC and -fobjc-arc-exceptions. */
#ifndef FULLFRAME_NATIVE_FRAME_QUEUE_H
#define FULLFRAME_NATIVE_FRAME_QUEUE_H
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stddef.h>

#define FFST_FRAME_QUEUE_DEFAULT_BYTES (256ull * 1024 * 1024)
#define FFST_FRAME_QUEUE_HARD_BYTES (512ull * 1024 * 1024)
#define FFST_FRAME_QUEUE_CAPACITY 2
#define FFST_FRAME_QUEUE_HISTORY 8
#define FFST_FRAME_QUEUE_EVIDENCE_BYTES 16384

@protocol FFSTQueuedFrame <NSObject>
@property(nonatomic, readonly) uint64_t streamID;
@property(nonatomic, readonly) uint64_t frameID;
@property(nonatomic, readonly) size_t retainedBytes;
@end

typedef NS_ENUM(NSInteger, FFSTFrameSubmitResult) {
    FFSTFrameAccepted = 0, FFSTFrameBackpressure, FFSTFrameClosed,
    FFSTFrameOrder, FFSTFrameInvalid
};
typedef NS_ENUM(NSInteger, FFSTFrameQueueError) {
    FFSTFrameCancelledBeforeExecution = 1, FFSTFrameInvalidBackendEvidence,
    FFSTFrameExecutorException
};
FOUNDATION_EXPORT NSString *const FFSTFrameQueueErrorDomain;
typedef BOOL (^FFSTFrameCancellation)(void);
/* Return YES only for the first completion; duplicates return NO. The executor
 * calls this only after all GPU/lease uses of the request have retired, even on
 * cancellation/error. Enqueue, scheduling and elapsed time are not that proof.
 * Evidence must be a bounded JSON dictionary; it is copied and never interpreted
 * as GPU success. Invalid evidence becomes a bounded queue error. */
typedef BOOL (^FFSTFrameExecutorCompletion)(NSDictionary *evidence, NSError *error);
typedef void (^FFSTFrameExecutor)(id<FFSTQueuedFrame> request,
    FFSTFrameCancellation cancelled, FFSTFrameExecutorCompletion completed);
typedef void (^FFSTFrameObserver)(uint64_t streamID, uint64_t frameID,
    BOOL cancelled, NSDictionary *evidence, NSError *error);

@interface FFSTNativeFrameQueue : NSObject
/* maxBytes==0 selects 256MiB; >512MiB rejects. The queue owns one serial execution
 * worker and one serial delivery queue targeting callbackQueue. No GPU/IPC work
 * is implemented here. Executor invocations never overlap, and the next request
 * starts only after the active executor reports retirement.
 *
 * At most two accepted requests are outstanding, including active, pending and
 * retired results awaiting observer delivery. This last reservation bounds slow
 * callback backlog without dropping evidence. Byte bounds include active+pending
 * requests; immutable callback evidence is separately capped at 16KiB/result.
 * The queue keeps itself alive while accepted work/results remain outstanding.
 * An executor exception flags cancellation but cannot imply GPU retirement; it
 * keeps active ownership until the saved completion callback is invoked.
 * Executor/observer blocks must not synchronously wait on their own queue. */
- (instancetype)initWithMaxRetainedBytes:(uint64_t)maxBytes
    callbackQueue:(dispatch_queue_t)callbackQueue executor:(FFSTFrameExecutor)executor
    observer:(FFSTFrameObserver)observer NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/* Thread safe, no GPU/network wait. Only Accepted retains the request. The caller
 * may then release its own reference; rejected requests remain entirely caller
 * owned. Request metadata/content must stay immutable throughout accepted work.
 * IDs must be nonzero. Within one stream, frameID strictly increases, with gaps
 * allowed. A stream switch requires strictly larger streamID and no active or
 * pending work (retired callback delivery may still be draining); frameID may
 * restart at 1. Rejected IDs do not advance the ordering cursor and may retry.
 * A request larger than maxBytes returns Invalid; a temporarily full queue
 * returns Backpressure. Old streams and reused IDs always return Order. No completed-ID set is kept. */
- (FFSTFrameSubmitResult)submit:(id<FFSTQueuedFrame>)request;
/* Cancellation is explicit, never a frame drop. Pending requests release their
 * ownership and receive an ordered cancellation result. Active requests only
 * see their cancellation predicate change; they stay retained until executor
 * completion. Future submissions are allowed after cancelAll/cancelStream. */
- (BOOL)cancelStream:(uint64_t)streamID frame:(uint64_t)frameID;
- (void)cancelAll;
/* Reject future submissions; cancel pending and flag active without releasing
 * active ownership. Does not wait, infer GPU retirement or stop another job. */
- (void)close;
/* Immutable bounded snapshots. History contains at most eight delivered actual
 * backend outcomes/explicit pending cancellations. Counters saturate at UINT64_MAX.
 * "retired" means executor reported retirement, not inferred rendering success. */
- (NSDictionary *)stats;
- (NSArray<NSDictionary *> *)history;
@end
#endif
