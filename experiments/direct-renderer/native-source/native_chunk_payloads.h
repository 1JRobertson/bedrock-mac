/* Immutable in-memory payload ownership for validated local chunk packets. ARC. */
#ifndef BEDROCK_NATIVE_CHUNK_PAYLOADS_H
#define BEDROCK_NATIVE_CHUNK_PAYLOADS_H
#import "native_session_execute.h"
#import "native_snapshot_arena.h"
#include "chunk_stream.h"

@interface FFSTDecodedNativeChunk : NSObject
@property(nonatomic,readonly) FFSTNativeChunkRequest *request;
@property(nonatomic,readonly) ffsc_packet_header header;
/* Exact immutable ffsc_retirement[] copy, including last_use_serial. */
@property(nonatomic,readonly) NSData *retirements;
@property(nonatomic,readonly) uint64_t ownedBytes;
/* One-shot request: drop blob views after execution/abandonment so arena pins
 * can retire while result metadata remains available. */
- (void)releasePreparedPayloads;
@end

/* One serialized transport consumer owns this cache. Cache content is keyed by
 * SHA256+length, independent of payload namespaces. No admission on a failed
 * decode, no implicit eviction, and no CACHED lookup into the current packet's
 * unconsumed INLINE|CACHE additions. Returned requests survive cache close.
 *
 * Decode copies records, blobs and retirement metadata before return; callers
 * may then return transport credit. SOURCE_READY and the exact completed
 * chunk.json publication are both mandatory. External waits are attested only
 * by exact completed dependency tuples in that GPU-ready publication. */
@interface FFSTNativeChunkPayloadCache : NSObject
- (instancetype)init;
- (instancetype)initWithMaxBytes:(uint64_t)bytes maxBlobs:(NSUInteger)blobs;
- (instancetype)initWithSnapshotArena:(FFSTNativeSnapshotArena *)arena;
- (FFSTDecodedNativeChunk *)decodePacket:(NSData *)packet failure:(NSString **)failure;
/* Only for the exact borrowed slot returned by successful ffsc_peek, before
 * ffsc_consume. That endpoint already validated layout/digest/order; decoder
 * still verifies content identities and owns all retained bytes before return. */
- (FFSTDecodedNativeChunk *)decodePeekedPacket:(NSData *)packet failure:(NSString **)failure;
/* cache_bytes/cache_blobs/next_serial/stream/closed; no GPU completion claims. */
- (NSDictionary *)stats;
- (void)close;
@end
#endif
