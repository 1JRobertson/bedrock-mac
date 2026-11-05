/* Incremental native chunks. ARC; one serialized owner per session. */
#ifndef BEDROCK_NATIVE_SESSION_EXECUTE_H
#define BEDROCK_NATIVE_SESSION_EXECUTE_H
#import "native_frame_execute.h"

@interface FFSTNativeChunkRequest : NSObject
@property(nonatomic,readonly) uint64_t serial,streamID,frameID,chunkID;
@property(nonatomic,readonly) uint64_t firstSequence,nextSequence,recordDigest;
@property(nonatomic,readonly) size_t retainedBytes;
@property(nonatomic,readonly) BOOL beginsFrame,endsFrame;
@property(nonatomic,readonly) NSData *records;
@property(nonatomic,readonly) id<FFSTNativeFramePayloadProvider> payloads;
/* Producer proves these allocation generations have no later source use.
 * Entries are {kind,root,allocation_generation,last_use_serial}; release follows native GPU
 * completion of this chunk. A new generation never aliases an older one. */
@property(nonatomic,readonly) NSArray<NSDictionary *> *retiredRoots;
/* Exactly one original CHUNK_BEGIN..CHUNK_END, optional original FRAME_BEGIN
 * prefix and FRAME_END suffix. Sequence remains global across frames. */
+ (instancetype)requestWithRecords:(NSData *)records serial:(uint64_t)serial
    retainedBytes:(size_t)bytes payloads:(id<FFSTNativeFramePayloadProvider>)payloads
    retiredRoots:(NSArray<NSDictionary *> *)retiredRoots failure:(NSString **)failure;
@end

@interface FFSTNativeChunkExecution : NSObject
@property(nonatomic,readonly) NSDictionary *metrics;
/* Present output is independently owned. pixels is nil unless diagnostic
 * readback was enabled. Non-Present chunks return nil frameOutput. */
@property(nonatomic,readonly) FFSTNativeFrameExecution *frameOutput;
/* Bounded packed native rows for source Map delivery; independent of the
 * optional diagnostic pixels and frameOutput. Empty for chunks without T2B. */
@property(nonatomic,readonly) NSArray<FFSTNativeBufferReadback *> *bufferReadbacks;
@end

@interface FFSTNativeSession : NSObject
- (instancetype)initWithMaxRetainedBytes:(uint64_t)maxBytes
    diagnosticReadback:(BOOL)readback;
/* Trusted authored-library resolver, used by native qualification fixtures. */
- (instancetype)initWithMaxRetainedBytes:(uint64_t)maxBytes
    diagnosticReadback:(BOOL)readback libraries:(FFSTPassLibraryResolver)libraries;
- (instancetype)init NS_UNAVAILABLE;
/* Synchronous real GPU completion; call from a serial background worker.
 * consumed fires once after payload ownership/encoding, before GPU commit.
 * It grants transport reuse only. Completion/query/presentation receipts are
 * separate. Failure poisons the session; close and create a new session. */
- (FFSTNativeChunkExecution *)executeChunk:(FFSTNativeChunkRequest *)request
    consumed:(void (^)(void))consumed cancelled:(BOOL (^)(void))cancelled
    failure:(NSString **)failure;
- (NSDictionary *)stats;
/* No in-flight work exists after executeChunk returns. */
- (void)close;
@end
#endif
